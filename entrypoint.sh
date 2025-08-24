#!/usr/bin/env sh
set -euo pipefail

echo "[boot] entrypoint v7.1 loaded" 

############################################
# Env (same as before)
############################################
: "${PB_ADMIN_EMAIL:?Set PB_ADMIN_EMAIL}"
: "${PB_ADMIN_PASSWORD:?Set PB_ADMIN_PASSWORD}"

PB_ENCRYPTION="${PB_ENCRYPTION:-}"
ENCRYPTION_ARG=""
[ -n "$PB_ENCRYPTION" ] && ENCRYPTION_ARG="--encryptionEnv PB_ENCRYPTION"

PB_PUBLIC_URL="${PB_PUBLIC_URL:-http://127.0.0.1:8090}"
PB_PUBLIC_URL="${PB_PUBLIC_URL%/}"

PB_S3_STORAGE_ENABLED="${PB_S3_STORAGE_ENABLED:-true}"
PB_S3_STORAGE_BUCKET="${PB_S3_STORAGE_BUCKET:-}"
PB_S3_STORAGE_REGION="${PB_S3_STORAGE_REGION:-}"
PB_S3_STORAGE_ENDPOINT="${PB_S3_STORAGE_ENDPOINT:-}"
PB_S3_STORAGE_ACCESS_KEY="${PB_S3_STORAGE_ACCESS_KEY:-}"
PB_S3_STORAGE_SECRET="${PB_S3_STORAGE_SECRET:-}"
PB_S3_STORAGE_FORCE_PATH_STYLE="${PB_S3_STORAGE_FORCE_PATH_STYLE:-false}"

PB_S3_BACKUPS_ENABLED="${PB_S3_BACKUPS_ENABLED:-true}"
PB_S3_BACKUPS_BUCKET="${PB_S3_BACKUPS_BUCKET:-}"
PB_S3_BACKUPS_REGION="${PB_S3_BACKUPS_REGION:-}"
PB_S3_BACKUPS_ENDPOINT="${PB_S3_BACKUPS_ENDPOINT:-}"
PB_S3_BACKUPS_ACCESS_KEY="${PB_S3_BACKUPS_ACCESS_KEY:-}"
PB_S3_BACKUPS_SECRET="${PB_S3_BACKUPS_SECRET:-}"
PB_S3_BACKUPS_FORCE_PATH_STYLE="${PB_S3_BACKUPS_FORCE_PATH_STYLE:-false}"
PB_BACKUPS_CRON="${PB_BACKUPS_CRON:-0 3 * * *}"
PB_BACKUPS_MAX_KEEP="${PB_BACKUPS_MAX_KEEP:-7}"

PB_RESTORE_FROM_S3="${PB_RESTORE_FROM_S3:-true}"
PB_BACKUP_BUCKET_URL="${PB_BACKUP_BUCKET_URL:-}"

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
export AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

AWS_S3_ENDPOINT="${AWS_S3_ENDPOINT:-}"
if [ -z "$AWS_S3_ENDPOINT" ]; then
  if [ -n "${PB_S3_BACKUPS_ENDPOINT:-}" ]; then
    AWS_S3_ENDPOINT="$PB_S3_BACKUPS_ENDPOINT"
  else
    AWS_S3_ENDPOINT="$PB_S3_STORAGE_ENDPOINT"
  fi
fi

############################################
# Tools & dirs
############################################
apk add --no-cache aws-cli unzip curl jq rsync >/dev/null 2>&1 || true

mkdir -p /pb_data /pb_migrations
if [ -d /app/pb_migrations ]; then
  rsync -a --update /app/pb_migrations/ /pb_migrations/
fi

############################################
# First boot: restore from Wasabi (if empty)
############################################
if [ ! -f /pb_data/data.db ] && [ "$PB_RESTORE_FROM_S3" = "true" ] && [ -n "$PB_BACKUP_BUCKET_URL" ]; then
  echo "[restore] No data.db; attempting restore from $PB_BACKUP_BUCKET_URL"
  LATEST_KEY="$(
    aws --endpoint-url "$AWS_S3_ENDPOINT" s3 ls "${PB_BACKUP_BUCKET_URL%/}/" \
    | awk '{print $4,$1,$2}' | sort -k2,3 | tail -n1 | awk '{print $1}'
  )"
  if [ -n "$LATEST_KEY" ]; then
    echo "[restore] Found backup: $LATEST_KEY"
    aws --endpoint-url "$AWS_S3_ENDPOINT" s3 cp \
      "${PB_BACKUP_BUCKET_URL%/}/${LATEST_KEY}" /tmp/pb_backup.zip
    unzip -o /tmp/pb_backup.zip -d /tmp/pb_restore
    if [ -d /tmp/pb_restore/pb_data ]; then
      cp -a /tmp/pb_restore/pb_data/. /pb_data/
      echo "[restore] Restore completed."
    else
      echo "[restore] Unexpected archive layout; skipping restore."
    fi
    rm -rf /tmp/pb_backup.zip /tmp/pb_restore
  else
    echo "[restore] No backups found at $PB_BACKUP_BUCKET_URL; starting fresh."
  fi
fi

############################################
# Initialize core + migrations
############################################
INIT_PORT=8097
echo "[init] Starting PB once on :${INIT_PORT} to initialize core/migrations…"
/app/pocketbase $ENCRYPTION_ARG \
  --dev \
  --dir /pb_data \
  --hooksDir /app/pb_hooks \
  --migrationsDir /pb_migrations \
  serve --http 127.0.0.1:${INIT_PORT} >/tmp/pb_init.log 2>&1 &
INIT_PID=$!

for i in $(seq 1 120); do
  sleep 0.25
  if curl -fsS "http://127.0.0.1:${INIT_PORT}/api/health" >/dev/null 2>&1; then
    sleep 0.5
    break
  fi
  [ "$i" -eq 120 ] && echo "[init] PB failed to start" && cat /tmp/pb_init.log && exit 1
done
kill $INIT_PID
wait $INIT_PID 2>/dev/null || true
echo "[init] Core/migrations initialized."

############################################
# Ensure admin exists + force password
############################################
echo "[admin] Creating admin (idempotent) for ${PB_ADMIN_EMAIL}"
CREATE_OUT=$(/app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
  admin create "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" 2>&1) || true
echo "[admin] create output:"
echo "$CREATE_OUT"

echo "[admin] Forcing password update"
/app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
  admin update "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" >/tmp/pb_admin_update.log 2>&1 || true
echo "[admin] update output:"
cat /tmp/pb_admin_update.log || true

############################################
# Bootstrap settings (S3 storage + backups) via API
############################################
BOOT_PORT=8099
echo "[bootstrap] Starting temporary PB on :${BOOT_PORT} for settings…"
/app/pocketbase $ENCRYPTION_ARG \
  --dev \
  --dir /pb_data \
  --hooksDir /app/pb_hooks \
  --migrationsDir /pb_migrations \
  serve --http 127.0.0.1:${BOOT_PORT} >/tmp/pb_bootstrap.log 2>&1 &
PB_PID=$!

for i in $(seq 1 120); do
  sleep 0.25
  if curl -fsS "http://127.0.0.1:${BOOT_PORT}/api/health" >/dev/null 2>&1; then break; fi
  [ "$i" -eq 120 ] && echo "[bootstrap] PB failed to start" && tail -n 200 /tmp/pb_bootstrap.log && exit 1
done

# Auth via JSON built with jq (no quoting issues)
AUTH_BODY="$(jq -n --arg id "$PB_ADMIN_EMAIL" --arg pw "$PB_ADMIN_PASSWORD" '{identity:$id, password:$pw}')"
AUTH_JSON="$(curl -sS -X POST "http://127.0.0.1:${BOOT_PORT}/api/admins/auth-with-password" \
  -H "Content-Type: application/json" --data-binary "$AUTH_BODY" || true)"
ADMIN_TOKEN="$(echo "$AUTH_JSON" | jq -r .token 2>/dev/null || echo "")"

if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
  echo "[bootstrap] Failed to obtain admin token. Response:"
  echo "$AUTH_JSON" | sed 's/"password":"[^"]*"/"password":"***"/'
  echo "--- bootstrap.log (tail) ---"
  tail -n 200 /tmp/pb_bootstrap.log || true
  kill $PB_PID; wait $PB_PID 2>/dev/null || true
  exit 1
fi

# Build settings JSON sections
META_JSON="$(jq -n --arg url "$PB_PUBLIC_URL" '{meta:{appName:"PocketBase",appUrl:$url}}')"

STOR_JSON="{}"
if [ "$PB_S3_STORAGE_ENABLED" = "true" ] \
   && [ -n "$PB_S3_STORAGE_BUCKET" ] && [ -n "$PB_S3_STORAGE_REGION" ] \
   && [ -n "$PB_S3_STORAGE_ENDPOINT" ] && [ -n "$PB_S3_STORAGE_ACCESS_KEY" ] \
   && [ -n "$PB_S3_STORAGE_SECRET" ]; then
  STOR_JSON="$(jq -n \
    --arg b  "$PB_S3_STORAGE_BUCKET" \
    --arg r  "$PB_S3_STORAGE_REGION" \
    --arg e  "$PB_S3_STORAGE_ENDPOINT" \
    --arg ak "$PB_S3_STORAGE_ACCESS_KEY" \
    --arg sk "$PB_S3_STORAGE_SECRET" \
    --argjson fps "$PB_S3_STORAGE_FORCE_PATH_STYLE" \
    '{enabled:true,bucket:$b,region:$r,endpoint:$e,accessKey:$ak,secret:$sk,forcePathStyle:$fps}')"
fi

BACK_JSON="{}"
if [ "$PB_S3_BACKUPS_ENABLED" = "true" ] \
   && [ -n "$PB_S3_BACKUPS_BUCKET" ] && [ -n "$PB_S3_BACKUPS_REGION" ] \
   && [ -n "$PB_S3_BACKUPS_ENDPOINT" ] && [ -n "$PB_S3_BACKUPS_ACCESS_KEY" ] \
   && [ -n "$PB_S3_BACKUPS_SECRET" ] && [ -n "$PB_BACKUPS_CRON" ] && [ -n "$PB_BACKUPS_MAX_KEEP" ]; then
  BACK_S3="$(jq -n \
    --arg b  "$PB_S3_BACKUPS_BUCKET" \
    --arg r  "$PB_S3_BACKUPS_REGION" \
    --arg e  "$PB_S3_BACKUPS_ENDPOINT" \
    --arg ak "$PB_S3_BACKUPS_ACCESS_KEY" \
    --arg sk "$PB_S3_BACKUPS_SECRET" \
    --argjson fps "$PB_S3_BACKUPS_FORCE_PATH_STYLE" \
    '{enabled:true,bucket:$b,region:$r,endpoint:$e,accessKey:$ak,secret:$sk,forcePathStyle:$fps}')"
  # FIX: don't use fromjson here; we already passed an object with --argjson
  BACK_JSON="$(jq -n \
    --arg cron "$PB_BACKUPS_CRON" \
    --argjson keep "$PB_BACKUPS_MAX_KEEP" \
    --argjson s3 "$BACK_S3" \
    '{cron:$cron,cronMaxKeep:($keep|tonumber),s3:$s3}')"
fi

# Merge payload (both STOR_JSON and BACK_JSON are already JSON objects)
SETTINGS_BODY="$(jq -n \
  --argjson meta "$META_JSON" \
  --argjson s3   "$STOR_JSON" \
  --argjson b    "$BACK_JSON" \
  '$meta + ( ( $s3|type=="object" and ($s3|length>0) ) ? {s3:$s3} : {} ) + ( ( $b|type=="object" and ($b|length>0)) ? {backups:$b} : {} )')"

# PATCH /api/settings
PATCH_OUT="$(mktemp)"
PATCH_CODE=0
echo "$SETTINGS_BODY" | curl -sS -w "%{http_code}" -o "$PATCH_OUT" \
  -X PATCH "http://127.0.0.1:${BOOT_PORT}/api/settings" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @- > /tmp/pb_patch_code.txt || PATCH_CODE=$?

HTTP_CODE="$(cat /tmp/pb_patch_code.txt || echo 000)"
if [ "$PATCH_CODE" -ne 0 ] || [ "$HTTP_CODE" -ge 400 ]; then
  echo "[bootstrap] Settings PATCH failed (HTTP $HTTP_CODE). Response:"
  cat "$PATCH_OUT"
  echo "--- bootstrap.log (tail) ---"
  tail -n 200 /tmp/pb_bootstrap.log || true
  kill $PB_PID; wait $PB_PID 2>/dev/null || true
  exit 1
fi
rm -f "$PATCH_OUT" /tmp/pb_patch_code.txt

# Optional connection tests
if [ "$PB_S3_STORAGE_ENABLED" = "true" ] && [ -n "$PB_S3_STORAGE_BUCKET" ]; then
  curl -fsS -X POST "http://127.0.0.1:${BOOT_PORT}/api/settings/test/s3" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
    -d '{"filesystem":"storage"}' >/dev/null || true
fi
if [ "$PB_S3_BACKUPS_ENABLED" = "true" ] && [ -n "$PB_S3_BACKUPS_BUCKET" ]; then
  curl -fsS -X POST "http://127.0.0.1:${BOOT_PORT}/api/settings/test/s3" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
    -d '{"filesystem":"backups"}' >/dev/null || true
fi

# Stop temp PB
kill $PB_PID
wait $PB_PID 2>/dev/null || true
echo "[bootstrap] Settings configured."

############################################
# Start the real server
############################################
exec /app/pocketbase $ENCRYPTION_ARG \
  --dir /pb_data \
  --hooksDir /app/pb_hooks \
  --migrationsDir /pb_migrations \
  serve --http 0.0.0.0:8090
