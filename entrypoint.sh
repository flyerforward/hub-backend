#!/usr/bin/env sh
set -euo pipefail

echo "[boot] entrypoint v4 loaded"

############################################
# Required/optional env vars
############################################

# --- Admin bootstrap ---
: "${PB_ADMIN_EMAIL:?Set PB_ADMIN_EMAIL}"
: "${PB_ADMIN_PASSWORD:?Set PB_ADMIN_PASSWORD}"

# Optional: encrypt secrets at rest in PB settings
PB_ENCRYPTION="${PB_ENCRYPTION:-}"
ENCRYPTION_ARG=""
[ -n "$PB_ENCRYPTION" ] && ENCRYPTION_ARG="--encryptionEnv PB_ENCRYPTION"

# Public URL stored in settings.meta.appUrl (NO trailing slash)
PB_PUBLIC_URL="${PB_PUBLIC_URL:-http://127.0.0.1:8090}"

# --- S3 storage (uploads) ---
PB_S3_STORAGE_ENABLED="${PB_S3_STORAGE_ENABLED:-true}"
PB_S3_STORAGE_BUCKET="${PB_S3_STORAGE_BUCKET:-}"
PB_S3_STORAGE_REGION="${PB_S3_STORAGE_REGION:-}"
PB_S3_STORAGE_ENDPOINT="${PB_S3_STORAGE_ENDPOINT:-}"
PB_S3_STORAGE_ACCESS_KEY="${PB_S3_STORAGE_ACCESS_KEY:-}"
PB_S3_STORAGE_SECRET="${PB_S3_STORAGE_SECRET:-}"
PB_S3_STORAGE_FORCE_PATH_STYLE="${PB_S3_STORAGE_FORCE_PATH_STYLE:-false}"

# --- S3 backups (PocketBase scheduled backups) ---
PB_S3_BACKUPS_ENABLED="${PB_S3_BACKUPS_ENABLED:-true}"
PB_S3_BACKUPS_BUCKET="${PB_S3_BACKUPS_BUCKET:-}"
PB_S3_BACKUPS_REGION="${PB_S3_BACKUPS_REGION:-}"
PB_S3_BACKUPS_ENDPOINT="${PB_S3_BACKUPS_ENDPOINT:-}"
PB_S3_BACKUPS_ACCESS_KEY="${PB_S3_BACKUPS_ACCESS_KEY:-}"
PB_S3_BACKUPS_SECRET="${PB_S3_BACKUPS_SECRET:-}"
PB_S3_BACKUPS_FORCE_PATH_STYLE="${PB_S3_BACKUPS_FORCE_PATH_STYLE:-false}"
PB_BACKUPS_CRON="${PB_BACKUPS_CRON:-0 3 * * *}"
PB_BACKUPS_MAX_KEEP="${PB_BACKUPS_MAX_KEEP:-7}"

# --- First-boot restore from S3 backup ZIP ---
PB_RESTORE_FROM_S3="${PB_RESTORE_FROM_S3:-true}"
PB_BACKUP_BUCKET_URL="${PB_BACKUP_BUCKET_URL:-}"    # e.g. s3://bucket or s3://bucket/prefix

# --- AWS CLI creds/region for restore (Wasabi) ---
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
export AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

# Ensure aws-cli talks to Wasabi (or other S3-compatible), not AWS S3
AWS_S3_ENDPOINT="${AWS_S3_ENDPOINT:-}"
if [ -z "$AWS_S3_ENDPOINT" ]; then
  if [ -n "${PB_S3_BACKUPS_ENDPOINT:-}" ]; then
    AWS_S3_ENDPOINT="$PB_S3_BACKUPS_ENDPOINT"
  else
    AWS_S3_ENDPOINT="$PB_S3_STORAGE_ENDPOINT"
  fi
fi

############################################
# Paths & initial sync
############################################
mkdir -p /pb_data /pb_migrations

# Sync repo migrations into runtime (no delete; preserve runtime-only files)
if [ -d /app/pb_migrations ]; then
  rsync -a --update /app/pb_migrations/ /pb_migrations/
fi

############################################
# First boot: auto-restore from S3 (if /pb_data empty)
############################################
if [ ! -f /pb_data/data.db ] && [ "$PB_RESTORE_FROM_S3" = "true" ] && [ -n "$PB_BACKUP_BUCKET_URL" ]; then
  echo "[restore] No data.db; attempting restore from $PB_BACKUP_BUCKET_URL"
  apk add --no-cache aws-cli unzip >/dev/null 2>&1 || true

  # Find newest object (by listing and sorting)
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
# Ensure an admin exists (ALWAYS attempt create; safe if already exists)
############################################
echo "[admin] Ensuring admin exists for ${PB_ADMIN_EMAIL}"
CREATE_OUT=""
if ! CREATE_OUT=$(/app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
      admin create "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" 2>&1); then
  echo "[admin] admin create returned non-zero (likely already exists). Output:"
  echo "$CREATE_OUT"
else
  echo "[admin] Admin created (or already present)."
fi

############################################
# Bootstrap settings (S3 storage + backups) via API
############################################
apk add --no-cache curl jq >/dev/null 2>&1 || true

BOOT_PORT=8099
echo "[bootstrap] Starting temporary PB on :${BOOT_PORT} for settings..."
/app/pocketbase $ENCRYPTION_ARG \
  --dir /pb_data \
  --hooksDir /app/pb_hooks \
  --migrationsDir /pb_migrations \
  serve --http 127.0.0.1:${BOOT_PORT} >/tmp/pb_bootstrap.log 2>&1 &
PB_PID=$!

# Wait for health
for i in $(seq 1 80); do
  sleep 0.25
  if curl -fsS "http://127.0.0.1:${BOOT_PORT}/api/health" >/dev/null 2>&1; then break; fi
  [ "$i" -eq 80 ] && echo "[bootstrap] PB failed to start" && cat /tmp/pb_bootstrap.log && exit 1
done

# Try to get admin token (with retries)
AUTH_JSON=""
ADMIN_TOKEN=""
for i in $(seq 1 10); do
  AUTH_JSON="$(curl -sS -X POST "http://127.0.0.1:${BOOT_PORT}/api/admins/auth-with-password" \
    -H "Content-Type: application/json" \
    -d "{\"identity\":\"$PB_ADMIN_EMAIL\",\"password\":\"$PB_ADMIN_PASSWORD\"}")" || AUTH_JSON=""
  ADMIN_TOKEN="$(echo "$AUTH_JSON" | jq -r .token 2>/dev/null || echo "")"
  if [ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ]; then
    break
  fi
  echo "[bootstrap] Admin auth attempt $i failed; retrying..."
  sleep 0.5
done

if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
  echo "[bootstrap] Failed to obtain admin token after retries. Last response:"
  echo "$AUTH_JSON" | sed 's/"password":"[^"]*"/"password":"***"/'
  cat /tmp/pb_bootstrap.log || true
  kill $PB_PID
  wait $PB_PID 2>/dev/null || true
  exit 1
fi

# Build settings JSON sections only if fully configured
SETTINGS_META="$(jq -n --arg url "$PB_PUBLIC_URL" '{meta:{appName:"PocketBase",appUrl:$url}}')"

STORAGE_JSON="{}"
if [ "$PB_S3_STORAGE_ENABLED" = "true" ] \
   && [ -n "$PB_S3_STORAGE_BUCKET" ] && [ -n "$PB_S3_STORAGE_REGION" ] \
   && [ -n "$PB_S3_STORAGE_ENDPOINT" ] && [ -n "$PB_S3_STORAGE_ACCESS_KEY" ] \
   && [ -n "$PB_S3_STORAGE_SECRET" ]; then
  STORAGE_JSON="$(jq -n \
    --arg b  "$PB_S3_STORAGE_BUCKET" \
    --arg r  "$PB_S3_STORAGE_REGION" \
    --arg e  "$PB_S3_STORAGE_ENDPOINT" \
    --arg ak "$PB_S3_STORAGE_ACCESS_KEY" \
    --arg sk "$PB_S3_STORAGE_SECRET" \
    --argjson fps "$PB_S3_STORAGE_FORCE_PATH_STYLE" \
    '{enabled:true,bucket:$b,region:$r,endpoint:$e,accessKey:$ak,secret:$sk,forcePathStyle:$fps}')"
fi

BACKUPS_JSON="{}"
if [ "$PB_S3_BACKUPS_ENABLED" = "true" ] \
   && [ -n "$PB_S3_BACKUPS_BUCKET" ] && [ -n "$PB_S3_BACKUPS_REGION" ] \
   && [ -n "$PB_S3_BACKUPS_ENDPOINT" ] && [ -n "$PB_S3_BACKUPS_ACCESS_KEY" ] \
   && [ -n "$PB_S3_BACKUPS_SECRET" ] && [ -n "$PB_BACKUPS_CRON" ] && [ -n "$PB_BACKUPS_MAX_KEEP" ]; then
  BACKUPS_S3="$(jq -n \
    --arg b  "$PB_S3_BACKUPS_BUCKET" \
    --arg r  "$PB_S3_BACKUPS_REGION" \
    --arg e  "$PB_S3_BACKUPS_ENDPOINT" \
    --arg ak "$PB_S3_BACKUPS_ACCESS_KEY" \
    --arg sk "$PB_S3_BACKUPS_SECRET" \
    --argjson fps "$PB_S3_BACKUPS_FORCE_PATH_STYLE" \
    '{enabled:true,bucket:$b,region:$r,endpoint:$e,accessKey:$ak,secret:$sk,forcePathStyle:$fps}')"
  BACKUPS_JSON="$(jq -n \
    --arg cron "$PB_BACKUPS_CRON" \
    --argjson keep "$PB_BACKUPS_MAX_KEEP" \
    --argjson s3 "$BACKUPS_S3" \
    '{cron:$cron,cronMaxKeep:($keep|tonumber),s3:($s3|fromjson)}')"
fi

# Merge payload
SETTINGS_BODY="$(jq -n \
  --argjson meta "$SETTINGS_META" \
  --argjson s3   "$STORAGE_JSON" \
  --argjson b    "$BACKUPS_JSON" \
  '$meta + ( ( $s3|type == "object" and ($s3|length>0) ) ? {s3:$s3} : {} ) + ( ( $b|type=="object" and ($b|length>0)) ? {backups:$b} : {} )')"

# PATCH /api/settings (Bearer token) and show body on error
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
  cat /tmp/pb_bootstrap.log || true
  kill $PB_PID
  wait $PB_PID 2>/dev/null || true
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
