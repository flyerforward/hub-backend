#!/usr/bin/env sh
set -euo pipefail

[ "${PB_DEBUG:-false}" = "true" ] && set -x

echo "[boot] entrypoint v7.50 (stateless, API-based temp service-admin) loaded"

############################################
# Env (minimal — no PB_ADMIN_* anymore)
############################################
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

# S3 backups
PB_S3_BACKUPS_ENABLED="${PB_S3_BACKUPS_ENABLED:-true}"
PB_S3_BACKUPS_BUCKET="${PB_S3_BACKUPS_BUCKET:-}"
PB_S3_BACKUPS_REGION="${PB_S3_BACKUPS_REGION:-}"
PB_S3_BACKUPS_ENDPOINT="${PB_S3_BACKUPS_ENDPOINT:-}"
PB_S3_BACKUPS_ACCESS_KEY="${PB_S3_BACKUPS_ACCESS_KEY:-}"
PB_S3_BACKUPS_SECRET="${PB_S3_BACKUPS_SECRET:-}"
PB_S3_BACKUPS_FORCE_PATH_STYLE="${PB_S3_BACKUPS_FORCE_PATH_STYLE:-false}"
PB_BACKUPS_CRON="${PB_BACKUPS_CRON:-0 3 * * *}"
PB_BACKUPS_MAX_KEEP="${PB_BACKUPS_MAX_KEEP:-7}"

############################################
# Tools & dirs
############################################
apk add --no-cache curl jq sqlite coreutils diffutils rsync >/dev/null 2>&1 || true
mkdir -p /pb_data /pb_migrations
[ -d /app/pb_migrations ] && rsync -a --update /app/pb_migrations/ /pb_migrations/

############################################
# Start PB (temp) on bootstrap port
############################################
BOOT_PORT=8099
start_temp() {
  /app/pocketbase $ENCRYPTION_ARG --dev --dir /pb_data \
    --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
    serve --http 127.0.0.1:${BOOT_PORT} >/tmp/pb_bootstrap.log 2>&1 &
  PB_PID=$!
  for i in $(seq 1 120); do
    sleep 0.25
    if curl -fsS "http://127.0.0.1:${BOOT_PORT}/api/health" >/dev/null 2>&1; then
      sleep 0.5; return 0
    fi
  done
  echo "[bootstrap] PB failed to start"; tail -n 200 /tmp/pb_bootstrap.log || true
  return 1
}
stop_temp() { kill $PB_PID 2>/dev/null || true; wait $PB_PID 2>/dev/null || true; }

############################################
# Generate disposable service admin creds
############################################
HASH="$(head -c 8 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8)"
SERVICE_ADMIN_EMAIL="admin-${HASH}@service.localhost"
SERVICE_ADMIN_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"

############################################
# 1) Start PB + create service admin via API
############################################
echo "[setup] Starting PB bootstrap on :${BOOT_PORT}…"
start_temp || { echo "[setup] Failed to start PB"; exit 1; }

echo "[setup] Creating temp service admin: $SERVICE_ADMIN_EMAIL"
CREATE_RESP=$(curl -sS -X POST "http://127.0.0.1:${BOOT_PORT}/api/admins" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$SERVICE_ADMIN_EMAIL\",\"password\":\"$SERVICE_ADMIN_PASSWORD\",\"passwordConfirm\":\"$SERVICE_ADMIN_PASSWORD\"}")

ADMIN_ID=$(echo "$CREATE_RESP" | jq -r .id || true)

# Authenticate service admin
AUTH_BODY="$(jq -n --arg id "$SERVICE_ADMIN_EMAIL" --arg pw "$SERVICE_ADMIN_PASSWORD" '{identity:$id, password:$pw}')"
AUTH_JSON="$(curl -sS -X POST "http://127.0.0.1:${BOOT_PORT}/api/admins/auth-with-password" \
  -H "Content-Type: application/json" --data-binary "$AUTH_BODY")"
ADMIN_TOKEN="$(echo "$AUTH_JSON" | jq -r .token || true)"

if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
  echo "[auth] ERROR: Could not authenticate service admin."
  tail -n 200 /tmp/pb_bootstrap.log || true
  stop_temp; exit 1
fi

############################################
# 2) Build desired settings
############################################
META_FILE="$(mktemp)"; STOR_FILE="$(mktemp)"; BACK_FILE="$(mktemp)"
DESIRED_FILE="$(mktemp)"; DESIRED_TRIM_FILE="$(mktemp)"
LIVE_FILE="$(mktemp)"; LIVE_TRIM_FILE="$(mktemp)"

jq -n --arg url "$PB_PUBLIC_URL" '{meta:{appName:"PocketBase",appUrl:$url}}' > "$META_FILE"

if [ "$PB_S3_STORAGE_ENABLED" = "true" ] \
   && [ -n "$PB_S3_STORAGE_BUCKET" ] && [ -n "$PB_S3_STORAGE_REGION" ] \
   && [ -n "$PB_S3_STORAGE_ENDPOINT" ] && [ -n "$PB_S3_STORAGE_ACCESS_KEY" ] \
   && [ -n "$PB_S3_STORAGE_SECRET" ]; then
  jq -n \
    --arg b "$PB_S3_STORAGE_BUCKET" --arg r "$PB_S3_STORAGE_REGION" \
    --arg e "$PB_S3_STORAGE_ENDPOINT" --arg ak "$PB_S3_STORAGE_ACCESS_KEY" \
    --arg sk "$PB_S3_STORAGE_SECRET" --argjson fps "$PB_S3_STORAGE_FORCE_PATH_STYLE" \
    '{s3:{enabled:true,bucket:$b,region:$r,endpoint:$e,accessKey:$ak,secret:$sk,forcePathStyle:$fps}}' > "$STOR_FILE"
else
  echo '{}' > "$STOR_FILE"
fi

if [ "$PB_S3_BACKUPS_ENABLED" = "true" ] \
   && [ -n "$PB_S3_BACKUPS_BUCKET" ] && [ -n "$PB_S3_BACKUPS_REGION" ] \
   && [ -n "$PB_S3_BACKUPS_ENDPOINT" ] && [ -n "$PB_S3_BACKUPS_ACCESS_KEY" ] \
   && [ -n "$PB_S3_BACKUPS_SECRET" ] && [ -n "$PB_BACKUPS_CRON" ] && [ -n "$PB_BACKUPS_MAX_KEEP" ]; then
  jq -n \
    --arg cron "$PB_BACKUPS_CRON" \
    --argjson keep "$(printf '%s' "$PB_BACKUPS_MAX_KEEP")" \
    --arg b "$PB_S3_BACKUPS_BUCKET" --arg r "$PB_S3_BACKUPS_REGION" \
    --arg e "$PB_S3_BACKUPS_ENDPOINT" --arg ak "$PB_S3_BACKUPS_ACCESS_KEY" \
    --arg sk "$PB_S3_BACKUPS_SECRET" --argjson fps "$PB_S3_BACKUPS_FORCE_PATH_STYLE" \
    '{backups:{cron:$cron,cronMaxKeep:$keep,s3:{enabled:true,bucket:$b,region:$r,endpoint:$e,accessKey:$ak,secret:$sk,forcePathStyle:$fps}}}' > "$BACK_FILE"
else
  echo '{}' > "$BACK_FILE"
fi

jq -s 'add' "$META_FILE" "$STOR_FILE" "$BACK_FILE" > "$DESIRED_FILE"
jq '{meta:{appUrl:.meta.appUrl}, s3, backups}' "$DESIRED_FILE" | jq -S . > "$DESIRED_TRIM_FILE"

############################################
# 3) Compare live vs desired settings, PATCH if needed
############################################
curl -fsS -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://127.0.0.1:${BOOT_PORT}/api/settings" > "$LIVE_FILE"
jq '{meta:{appUrl:.meta.appUrl}, s3, backups}' "$LIVE_FILE" | jq -S . > "$LIVE_TRIM_FILE"

if ! diff -q "$DESIRED_TRIM_FILE" "$LIVE_TRIM_FILE" >/dev/null 2>&1; then
  echo "[settings] Applying settings changes…"
  PATCH_OUT="$(mktemp)"
  HTTP_CODE=$(cat "$DESIRED_FILE" | curl -sS -w "%{http_code}" -o "$PATCH_OUT" \
    -X PATCH "http://127.0.0.1:${BOOT_PORT}/api/settings" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
    --data-binary @-)
  if [ "$HTTP_CODE" -ge 400 ]; then
    echo "[settings] PATCH failed (HTTP $HTTP_CODE). Response:"; cat "$PATCH_OUT"
    stop_temp; exit 1
  fi
else
  echo "[settings] No changes needed."
fi

rm -f "$META_FILE" "$STOR_FILE" "$BACK_FILE" "$DESIRED_FILE" "$DESIRED_TRIM_FILE" \
      "$LIVE_FILE" "$LIVE_TRIM_FILE" 2>/dev/null || true

############################################
# 4) Delete service admin
############################################
if [ -n "$ADMIN_ID" ] && [ "$ADMIN_ID" != "null" ]; then
  curl -sS -X DELETE "http://127.0.0.1:${BOOT_PORT}/api/admins/$ADMIN_ID" \
    -H "Authorization: Bearer $ADMIN_TOKEN" >/dev/null 2>&1 || true
  echo "[setup] Deleted temp service admin: $SERVICE_ADMIN_EMAIL"
fi

############################################
# 5) Stop bootstrap PB + start real server
############################################
stop_temp
echo "[bootstrap] Done."

exec /app/pocketbase $ENCRYPTION_ARG \
  --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
  serve --http 0.0.0.0:8090
