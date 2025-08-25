#!/usr/bin/env sh
set -euo pipefail

echo "[boot] entrypoint v7.10 loaded"

############################################
# Env
############################################
: "${PB_ADMIN_EMAIL:?Set PB_ADMIN_EMAIL}"
: "${PB_ADMIN_PASSWORD:?Set PB_ADMIN_PASSWORD}"

# Keep only the env admin (delete others) if true
PB_ADMIN_ENFORCE_SINGLE="${PB_ADMIN_ENFORCE_SINGLE:-true}"

PB_ENCRYPTION="${PB_ENCRYPTION:-}"
ENCRYPTION_ARG=""
[ -n "$PB_ENCRYPTION" ] && ENCRYPTION_ARG="--encryptionEnv PB_ENCRYPTION"

PB_PUBLIC_URL="${PB_PUBLIC_URL:-http://127.0.0.1:8090}"
PB_PUBLIC_URL="${PB_PUBLIC_URL%/}"

# S3 storage (uploads)
PB_S3_STORAGE_ENABLED="${PB_S3_STORAGE_ENABLED:-true}"
PB_S3_STORAGE_BUCKET="${PB_S3_STORAGE_BUCKET:-}"
PB_S3_STORAGE_REGION="${PB_S3_STORAGE_REGION:-}"
PB_S3_STORAGE_ENDPOINT="${PB_S3_STORAGE_ENDPOINT:-}"
PB_S3_STORAGE_ACCESS_KEY="${PB_S3_STORAGE_ACCESS_KEY:-}"
PB_S3_STORAGE_SECRET="${PB_S3_STORAGE_SECRET:-}"
PB_S3_STORAGE_FORCE_PATH_STYLE="${PB_S3_STORAGE_FORCE_PATH_STYLE:-false}"

# S3 backups (PocketBase cron)
PB_S3_BACKUPS_ENABLED="${PB_S3_BACKUPS_ENABLED:-true}"
PB_S3_BACKUPS_BUCKET="${PB_S3_BACKUPS_BUCKET:-}"
PB_S3_BACKUPS_REGION="${PB_S3_BACKUPS_REGION:-}"
PB_S3_BACKUPS_ENDPOINT="${PB_S3_BACKUPS_ENDPOINT:-}"
PB_S3_BACKUPS_ACCESS_KEY="${PB_S3_BACKUPS_ACCESS_KEY:-}"
PB_S3_BACKUPS_SECRET="${PB_S3_BACKUPS_SECRET:-}"
PB_S3_BACKUPS_FORCE_PATH_STYLE="${PB_S3_BACKUPS_FORCE_PATH_STYLE:-false}"
PB_BACKUPS_CRON="${PB_BACKUPS_CRON:-0 3 * * *}"
PB_BACKUPS_MAX_KEEP="${PB_BACKUPS_MAX_KEEP:-7}"

# Restore from S3 (first boot)
PB_RESTORE_FROM_S3="${PB_RESTORE_FROM_S3:-true}"
PB_BACKUP_BUCKET_URL="${PB_BACKUP_BUCKET_URL:-}"

# AWS CLI (Wasabi)
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
apk add --no-cache aws-cli unzip curl jq rsync sqlite >/dev/null 2>&1 || true
mkdir -p /pb_data /pb_migrations
[ -d /app/pb_migrations ] && rsync -a --update /app/pb_migrations/ /pb_migrations/

############################################
# First boot restore (root-files layout only)
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
    if [ -f /tmp/pb_restore/data.db ]; then
      echo "[restore] Using 'root files' layout from archive."
      cp -a /tmp/pb_restore/. /pb_data/
      echo "[restore] Restore completed."
    else
      echo "[restore] Required files not found at archive root; skipping restore."
    fi
    rm -rf /tmp/pb_backup.zip /tmp/pb_restore
  else
    echo "[restore] No backups found at $PB_BACKUP_BUCKET_URL; starting fresh."
  fi
fi

############################################
# Initialize core + migrations (one-time)
############################################
INIT_PORT=8097
echo "[init] Starting PB once on :${INIT_PORT} to initialize core/migrations…"
/app/pocketbase $ENCRYPTION_ARG \
  --dev --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
  serve --http 127.0.0.1:${INIT_PORT} >/tmp/pb_init.log 2>&1 &
INIT_PID=$!

for i in $(seq 1 120); do
  sleep 0.25
  if curl -fsS "http://127.0.0.1:${INIT_PORT}/api/health" >/dev/null 2>&1; then
    sleep 0.5; break
  fi
  [ "$i" -eq 120 ] && echo "[init] PB failed to start" && cat /tmp/pb_init.log && exit 1
done
kill $INIT_PID; wait $INIT_PID 2>/dev/null || true
echo "[init] Core/migrations initialized."

############################################
# Admin enforcement
############################################
ADMINS_TOTAL=$(sqlite3 /pb_data/data.db "SELECT COUNT(*) FROM _admins;" 2>/dev/null || echo 0)
ESC_EMAIL="$(printf "%s" "$PB_ADMIN_EMAIL" | sed "s/'/''/g")"
EMAIL_COUNT=$(sqlite3 /pb_data/data.db "SELECT COUNT(*) FROM _admins WHERE email = '$ESC_EMAIL';" 2>/dev/null || echo 0)

if [ "${ADMINS_TOTAL:-0}" -eq 0 ]; then
  echo "[admin] No admins found; creating $PB_ADMIN_EMAIL"
  /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
    admin create "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" >/tmp/pb_admin_create.log 2>&1 || true
  echo "[admin] create output:"; cat /tmp/pb_admin_create.log || true
elif [ "${EMAIL_COUNT:-0}" -gt 0 ]; then
  echo "[admin] Env admin already exists; will not rotate password unless needed."
else
  if [ "$PB_ADMIN_ENFORCE_SINGLE" = "true" ]; then
    echo "[admin] Admin(s) exist but not '$PB_ADMIN_EMAIL' → enforcing single admin: deleting all others."
    for em in $(sqlite3 -newline $'\n' /pb_data/data.db "SELECT email FROM _admins;"); do
      if [ "$em" != "$PB_ADMIN_EMAIL" ]; then
        echo "[admin] Deleting admin: $em"
        /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
          admin delete "$em" >/tmp/pb_admin_delete.log 2>&1 || true
      fi
    done
    echo "[admin] Creating env admin after deletion."
    /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
      admin create "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" >/tmp/pb_admin_create.log 2>&1 || true
    echo "[admin] create output:"; cat /tmp/pb_admin_create.log || true
  else
    echo "[admin] PB_ADMIN_ENFORCE_SINGLE=false → leaving existing admins."
  fi
fi

############################################
# Build "desired" settings as files (no inline jq)
############################################
META_FILE="$(mktemp)"; STOR_FILE="$(mktemp)"; BACK_FILE="$(mktemp)"
jq -n --arg url "$PB_PUBLIC_URL" '{meta:{appName:"PocketBase",appUrl:$url}}' > "$META_FILE"

if [ "$PB_S3_STORAGE_ENABLED" = "true" ] \
   && [ -n "$PB_S3_STORAGE_BUCKET" ] && [ -n "$PB_S3_STORAGE_REGION" ] \
   && [ -n "$PB_S3_STORAGE_ENDPOINT" ] && [ -n "$PB_S3_STORAGE_ACCESS_KEY" ] \
   && [ -n "$PB_S3_STORAGE_SECRET" ]; then
  jq -n \
    --arg b  "$PB_S3_STORAGE_BUCKET" \
    --arg r  "$PB_S3_STORAGE_REGION" \
    --arg e  "$PB_S3_STORAGE_ENDPOINT" \
    --arg ak "$PB_S3_STORAGE_ACCESS_KEY" \
    --arg sk "$PB_S3_STORAGE_SECRET" \
    --argjson fps "$PB_S3_STORAGE_FORCE_PATH_STYLE" \
    '{s3:{enabled:true,bucket:$b,region:$r,endpoint:$e,accessKey:$ak,secret:$sk,forcePathStyle:$fps}}' > "$STOR_FILE"
else
  echo '{}' > "$STOR_FILE"
fi

if [ "$PB_S3_BACKUPS_ENABLED" = "true" ] \
   && [ -n "$PB_S3_BACKUPS_BUCKET" ] && [ -n "$PB_S3_BACKUPS_REGION" ] \
   && [ -n "$PB_S3_BACKUPS_ENDPOINT" ] && [ -n "$PB_S3_BACKUPS_ACCESS_KEY" ] \
   && [ -n "$PB_S3_BACKUPS_SECRET" ] && [ -n "$PB_BACKUPS_CRON" ] && [ -n "$PB_BACKUPS_MAX_KEEP" ]; then
  # ensure keep is numeric to jq
  jq -n \
    --arg cron "$PB_BACKUPS_CRON" \
    --argjson keep "$(printf '%s' "$PB_BACKUPS_MAX_KEEP")" \
    --arg b  "$PB_S3_BACKUPS_BUCKET" \
    --arg r  "$PB_S3_BACKUPS_REGION" \
    --arg e  "$PB_S3_BACKUPS_ENDPOINT" \
    --arg ak "$PB_S3_BACKUPS_ACCESS_KEY" \
    --arg sk "$PB_S3_BACKUPS_SECRET" \
    --argjson fps "$PB_S3_BACKUPS_FORCE_PATH_STYLE" \
    '{backups:{cron:$cron,cronMaxKeep:$keep,s3:{enabled:true,bucket:$b,region:$r,endpoint:$e,accessKey:$ak,secret:$sk,forcePathStyle:$fps}}}' > "$BACK_FILE"
else
  echo '{}' > "$BACK_FILE"
fi

DESIRED_FILE="$(mktemp)"
jq -s 'add' "$META_FILE" "$STOR_FILE" "$BACK_FILE" > "$DESIRED_FILE"

############################################
# Compare desired vs current (avoid login if no change)
############################################
CURRENT_RAW="$(sqlite3 /pb_data/data.db "SELECT value FROM _params WHERE key='settings' LIMIT 1;" 2>/dev/null || echo '')"
if [ -z "$CURRENT_RAW" ]; then
  echo "[settings] No existing settings row; will apply desired settings."
  NEEDS_PATCH="yes"
else
  CURRENT_TRIM="$(printf '%s' "$CURRENT_RAW" | jq '{meta:{appUrl:.meta.appUrl}, s3, backups}')"
  DESIRED_TRIM="$(jq '{meta:{appUrl:.meta.appUrl}, s3, backups}' "$DESIRED_FILE")"
  if diff -u <(printf '%s' "$CURRENT_TRIM" | jq -S .) <(printf '%s' "$DESIRED_TRIM" | jq -S .) >/dev/null 2>&1; then
    echo "[settings] Current settings already match desired. Skipping admin login & PATCH."
    exec /app/pocketbase $ENCRYPTION_ARG \
      --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
      serve --http 0.0.0.0:8090
  else
    echo "[settings] Settings differ; will login and PATCH."
  fi
fi

############################################
# Temp server for settings & conditional password update
############################################
BOOT_PORT=8099
echo "[bootstrap] Starting temporary PB on :${BOOT_PORT} for settings (changes pending)…"
/app/pocketbase $ENCRYPTION_ARG \
  --dev --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
  serve --http 127.0.0.1:${BOOT_PORT} >/tmp/pb_bootstrap.log 2>&1 &
PB_PID=$!

for i in $(seq 1 120); do
  sleep 0.25
  if curl -fsS "http://127.0.0.1:${BOOT_PORT}/api/health" >/dev/null 2>&1; then break; fi
  [ "$i" -eq 120 ] && echo "[bootstrap] PB failed to start" && tail -n 200 /tmp/pb_bootstrap.log && exit 1
done

AUTH_BODY="$(jq -n --arg id "$PB_ADMIN_EMAIL" --arg pw "$PB_ADMIN_PASSWORD" '{identity:$id, password:$pw}')"
try_auth() {
  curl -sS -X POST "http://127.0.0.1:${BOOT_PORT}/api/admins/auth-with-password" \
    -H "Content-Type: application/json" --data-binary "$AUTH_BODY" || true
}
AUTH_JSON="$(try_auth)"
ADMIN_TOKEN="$(echo "$AUTH_JSON" | jq -r .token 2>/dev/null || echo "")"

if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
  echo "[admin] Env password didn’t match DB; updating password for $PB_ADMIN_EMAIL"
  /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
    admin update "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" >/tmp/pb_admin_update.log 2>&1 || true
  echo "[admin] update output:"; cat /tmp/pb_admin_update.log || true

  AUTH_JSON="$(try_auth)"
  ADMIN_TOKEN="$(echo "$AUTH_JSON" | jq -r .token 2>/dev/null || echo "")"
  if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
    echo "[bootstrap] Auth still failing after password update. Response:"
    echo "$AUTH_JSON" | sed 's/"password":"[^"]*"/"password":"***"/'
    echo "--- bootstrap.log (tail) ---"; tail -n 200 /tmp/pb_bootstrap.log || true
    kill $PB_PID; wait $PB_PID 2>/dev/null || true
    exit 1
  fi
else
  echo "[admin] Env password matches DB."
fi

# PATCH settings
PATCH_OUT="$(mktemp)"; PATCH_CODE=0
cat "$DESIRED_FILE" | curl -sS -w "%{http_code}" -o "$PATCH_OUT" \
  -X PATCH "http://127.0.0.1:${BOOT_PORT}/api/settings" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  --data-binary @- > /tmp/pb_patch_code.txt || PATCH_CODE=$?
HTTP_CODE="$(cat /tmp/pb_patch_code.txt || echo 000)"
if [ "$PATCH_CODE" -ne 0 ] || [ "$HTTP_CODE" -ge 400 ]; then
  echo "[bootstrap] Settings PATCH failed (HTTP $HTTP_CODE). Response:"; cat "$PATCH_OUT"
  echo "--- bootstrap.log (tail) ---"; tail -n 200 /tmp/pb_bootstrap.log || true
  kill $PB_PID; wait $PB_PID 2>/dev/null || true
  exit 1
fi

# Cleanup temp files & start real server
rm -f "$META_FILE" "$STOR_FILE" "$BACK_FILE" "$DESIRED_FILE" "$PATCH_OUT" /tmp/pb_patch_code.txt 2>/dev/null || true
kill $PB_PID; wait $PB_PID 2>/dev/null || true
echo "[bootstrap] Settings configured."

exec /app/pocketbase $ENCRYPTION_ARG \
  --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
  serve --http 0.0.0.0:8090
