#!/usr/bin/env sh
set -euo pipefail
[ "${PB_DEBUG:-false}" = "true" ] && set -x

echo "[boot] entrypoint v7.51 (stateless, API-based temp service-admin w/ migration wait) loaded"

PB_ENCRYPTION="${PB_ENCRYPTION:-}"
ENCRYPTION_ARG=""
[ -n "$PB_ENCRYPTION" ] && ENCRYPTION_ARG="--encryptionEnv PB_ENCRYPTION"

PB_PUBLIC_URL="${PB_PUBLIC_URL:-http://127.0.0.1:8090}"
PB_PUBLIC_URL="${PB_PUBLIC_URL%/}"

# S3 storage
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

apk add --no-cache curl jq sqlite coreutils rsync >/dev/null 2>&1 || true
mkdir -p /pb_data /pb_migrations
[ -d /app/pb_migrations ] && rsync -a --update /app/pb_migrations/ /pb_migrations/

sql() { sqlite3 /pb_data/data.db "$1" 2>/dev/null || true; }

BOOT_PORT=8099
start_temp() {
  /app/pocketbase $ENCRYPTION_ARG --dev --dir /pb_data \
    --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
    serve --http 127.0.0.1:${BOOT_PORT} >/tmp/pb_bootstrap.log 2>&1 &
  PB_PID=$!

  # Wait until health + migrations (_admins table exists)
  echo "[setup] Waiting for PB + migrations…"
  for i in $(seq 1 240); do
    sleep 0.25
    if curl -fsS "http://127.0.0.1:${BOOT_PORT}/api/health" >/dev/null 2>&1; then
      if sql "SELECT name FROM sqlite_master WHERE type='table' AND name='_admins';" | grep -q "_admins"; then
        echo "[setup] PB ready (migrations applied)."
        return 0
      fi
    fi
  done
  echo "[bootstrap] PB failed to start fully"; tail -n 200 /tmp/pb_bootstrap.log || true
  return 1
}
stop_temp() { kill $PB_PID 2>/dev/null || true; wait $PB_PID 2>/dev/null || true; }

# Generate disposable service admin creds
HASH="$(head -c 8 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8)"
SERVICE_ADMIN_EMAIL="admin-${HASH}@service.localhost"
SERVICE_ADMIN_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"

# Start PB + wait for migrations
echo "[setup] Starting PB bootstrap on :${BOOT_PORT}…"
start_temp || exit 1

# Create service admin
echo "[setup] Creating temp service admin: $SERVICE_ADMIN_EMAIL"
CREATE_RESP=$(curl -sS -X POST "http://127.0.0.1:${BOOT_PORT}/api/admins" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$SERVICE_ADMIN_EMAIL\",\"password\":\"$SERVICE_ADMIN_PASSWORD\",\"passwordConfirm\":\"$SERVICE_ADMIN_PASSWORD\"}")
ADMIN_ID=$(echo "$CREATE_RESP" | jq -r .id || true)

# Auth
AUTH_BODY="$(jq -n --arg id "$SERVICE_ADMIN_EMAIL" --arg pw "$SERVICE_ADMIN_PASSWORD" '{identity:$id, password:$pw}')"
AUTH_JSON="$(curl -sS -X POST "http://127.0.0.1:${BOOT_PORT}/api/admins/auth-with-password" \
  -H "Content-Type: application/json" --data-binary "$AUTH_BODY")"
ADMIN_TOKEN="$(echo "$AUTH_JSON" | jq -r .token || true)"

if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
  echo "[auth] ERROR: Could not authenticate service admin."
  tail -n 200 /tmp/pb_bootstrap.log || true
  stop_temp; exit 1
fi

# --- apply settings (same as before) ---
# (trimmed here for brevity — patch logic unchanged)

# Delete service admin
if [ -n "$ADMIN_ID" ] && [ "$ADMIN_ID" != "null" ]; then
  curl -sS -X DELETE "http://127.0.0.1:${BOOT_PORT}/api/admins/$ADMIN_ID" \
    -H "Authorization: Bearer $ADMIN_TOKEN" >/dev/null 2>&1 || true
  echo "[setup] Deleted temp service admin: $SERVICE_ADMIN_EMAIL"
fi

stop_temp
echo "[bootstrap] Done."

exec /app/pocketbase $ENCRYPTION_ARG \
  --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
  serve --http 0.0.0.0:8090
