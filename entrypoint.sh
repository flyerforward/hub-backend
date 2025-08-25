#!/usr/bin/env sh
set -euo pipefail

[ "${PB_DEBUG:-false}" = "true" ] && set -x

echo "[boot] entrypoint v7.41 (stateless, temp service-admin with valid email) loaded"

############################################
# Env (no PB_ADMIN_* anymore)
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

sql() { sqlite3 /pb_data/data.db "$1"; }

############################################
# 1) Init core + migrations
############################################
INIT_PORT=8097
echo "[init] Starting PB once on :${INIT_PORT}…"
/app/pocketbase $ENCRYPTION_ARG --dev --dir /pb_data \
  --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
  serve --http 127.0.0.1:${INIT_PORT} >/tmp/pb_init.log 2>&1 &
INIT_PID=$!
for i in $(seq 1 120); do
  sleep 0.25
  if curl -fsS "http://127.0.0.1:${INIT_PORT}/api/health" >/dev/null 2>&1; then sleep 0.5; break; fi
  [ "$i" -eq 120 ] && echo "[init] PB failed to start" && cat /tmp/pb_init.log && exit 1
done
kill $INIT_PID; wait $INIT_PID 2>/dev/null || true
echo "[init] Core/migrations initialized."

############################################
# 2) Create temporary service admin
############################################
HASH="$(head -c 8 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8)"
SERVICE_ADMIN_EMAIL="admin-${HASH}@service.localhost"
SERVICE_ADMIN_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"

echo "[setup] Creating temp service admin: ${SERVICE_ADMIN_EMAIL}"
/app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
  admin create "$SERVICE_ADMIN_EMAIL" "$SERVICE_ADMIN_PASSWORD" >/tmp/pb_admin_create.log 2>&1 || true
cat /tmp/pb_admin_create.log || true

############################################
# 3) Start PB for settings patch
############################################
BOOT_PORT=8099
start_temp() {
  /app/pocketbase $ENCRYPTION_ARG --dev --dir /pb_data \
    --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
    serve --http 127.0.0.1:${BOOT_PORT} >/tmp/pb_bootstrap.log 2>&1 &
  PB_PID=$!
  for i in $(seq 1 120); do
    sleep 0.25
    if curl -fsS "http://127.0.0.1:${BOOT_PORT}/api/health" >/dev/null 2>&1; then return 0; fi
  done
  echo "[bootstrap] PB failed to start"; tail -n 200 /tmp/pb_bootstrap.log || true; return 1
}
stop_temp() { kill $PB_PID 2>/dev/null || true; wait $PB_PID 2>/dev/null || true; }

AUTH_BODY="$(jq -n --arg id "$SERVICE_ADMIN_EMAIL" --arg pw "$SERVICE_ADMIN_PASSWORD" '{identity:$id, password:$pw}')"
try_auth() {
  curl -sS -X POST "http://127.0.0.1:${BOOT_PORT}/api/admins/auth-with-password" \
    -H "Content-Type: application/json" --data-binary "$AUTH_BODY" || true
}

echo "[auth] Starting temp PB for settings patch…"
start_temp
AUTH_JSON="$(try_auth)"
ADMIN_TOKEN="$(echo "$AUTH_JSON" | jq -r .token 2>/dev/null || echo "")"
if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
  echo "[auth] ERROR: Service admin auth failed."; tail -n 200 /tmp/pb_bootstrap.log || true
  stop_temp; exit 1
fi

############################################
# 4) Apply settings
############################################
# (unchanged from v7.40 — compare & PATCH S3/backups/public URL settings)

# … [snip: same as before]

############################################
# 5) Stop temp PB and delete service admin
############################################
stop_temp
echo "[setup] Deleting temp service admin: ${SERVICE_ADMIN_EMAIL}"
/app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
  admin delete "$SERVICE_ADMIN_EMAIL" >/tmp/pb_admin_delete.log 2>&1 || true
cat /tmp/pb_admin_delete.log || true

sql "DELETE FROM _admins WHERE email='$(printf "%s" "$SERVICE_ADMIN_EMAIL" | sed "s/'/''/g")';" || true
echo "[setup] Service admin removed."

############################################
# 6) Start real server
############################################
echo "[bootstrap] Done."

exec /app/pocketbase $ENCRYPTION_ARG \
  --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
  serve --http 0.0.0.0:8090
