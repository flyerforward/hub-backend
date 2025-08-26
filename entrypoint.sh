#!/usr/bin/env sh
set -euo pipefail

[ "${PB_DEBUG:-false}" = "true" ] && set -x

echo "[boot] entrypoint v7.25 (stateless, temp-admin bootstrap, no-restore) loaded"

############################################
# Env (no admin creds needed)
############################################
# Public URL + optional encryption
PB_PUBLIC_URL="${PB_PUBLIC_URL:-http://127.0.0.1:8090}"
PB_PUBLIC_URL="${PB_PUBLIC_URL%/}"
PB_ENCRYPTION="${PB_ENCRYPTION:-}"
ENCRYPTION_ARG=""
[ -n "$PB_ENCRYPTION" ] && ENCRYPTION_ARG="--encryptionEnv PB_ENCRYPTION"

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

############################################
# Tools & dirs
############################################
apk add --no-cache curl jq sqlite coreutils diffutils rsync >/dev/null 2>&1 || true
mkdir -p /pb_data /pb_migrations
[ -d /app/pb_migrations ] && rsync -a --update /app/pb_migrations/ /pb_migrations/

sql() { sqlite3 /pb_data/data.db "$1"; }
wal_ckpt() { sqlite3 /pb_data/data.db "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true; }

############################################
# Init core + migrations (one-time fire)
############################################
INIT_PORT=8097
echo "[init] Starting PB once on :${INIT_PORT}…"
/app/pocketbase $ENCRYPTION_ARG --dev --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
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
# Temp PB helpers
############################################
BOOT_PORT=8099
start_temp() {
  /app/pocketbase $ENCRYPTION_ARG --dev --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
    serve --http 127.0.0.1:${BOOT_PORT} >/tmp/pb_bootstrap.log 2>&1 &
  PB_PID=$!
  for i in $(seq 1 120); do
    sleep 0.25
    if curl -fsS "http://127.0.0.1:${BOOT_PORT}/api/health" >/dev/null 2>&1; then return 0; fi
  done
  echo "[bootstrap] PB failed to start"; tail -n 200 /tmp/pb_bootstrap.log || true; return 1
}
stop_temp() { kill $PB_PID 2>/dev/null || true; wait $PB_PID 2>/dev/null || true; }

# Auth with temp admin
auth_token() {
  local email="$1" pw="$2"
  local body; body="$(jq -n --arg id "$email" --arg pw "$pw" '{identity:$id, password:$pw}')"
  curl -sS -X POST "http://127.0.0.1:${BOOT_PORT}/api/admins/auth-with-password" \
    -H "Content-Type: application/json" --data-binary "$body" | jq -r '.token // empty'
}

############################################
# Create temporary service admin
############################################
# Generate unique email/password
RANDHEX="$(head -c16 /dev/urandom | od -An -t x1 | tr -d ' \n')"
TEMP_ADMIN_EMAIL="admin-${RANDHEX}@service.local"
TEMP_ADMIN_PASSWORD="$(head -c24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c32)"

# Safety: ensure not colliding (ultra unlikely, but cheap check)
EXISTS="$(sql "SELECT COUNT(*) FROM _admins WHERE email='${TEMP_ADMIN_EMAIL//\'/\'\'}';" 2>/dev/null || echo 0)"
if [ "${EXISTS:-0}" -gt 0 ]; then
  echo "[temp-admin] Collision on generated email (unlikely). Regenerating…"
  RANDHEX="$(head -c16 /dev/urandom | od -An -t x1 | tr -d ' \n')"
  TEMP_ADMIN_EMAIL="admin-${RANDHEX}@service.local"
fi

echo "[temp-admin] Creating temporary admin: $TEMP_ADMIN_EMAIL"
/app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
  admin create "$TEMP_ADMIN_EMAIL" "$TEMP_ADMIN_PASSWORD" >/tmp/pb_admin_create.log 2>&1 || true
cat /tmp/pb_admin_create.log || true

# Ensure temp server running for API
echo "[bootstrap] Starting temp PB for settings apply…"
start_temp

# Get token
ADMIN_TOKEN="$(auth_token "$TEMP_ADMIN_EMAIL" "$TEMP_ADMIN_PASSWORD")"
if [ -z "$ADMIN_TOKEN" ]; then
  echo "[temp-admin] ERROR: could not authenticate temp admin."
  tail -n 200 /tmp/pb_bootstrap.log || true
  stop_temp
  # Best-effort cleanup (delete temp admin offline)
  /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
    admin delete "$TEMP_ADMIN_EMAIL" >/tmp/pb_admin_delete.log 2>&1 || true
  exit 1
fi

############################################
# Settings (STATELESS): build → diff → PATCH
############################################
META_FILE="$(mktemp)"; STOR_FILE="$(mktemp)"; BACK_FILE="$(mktemp)"
DESIRED_FILE="$(mktemp)"; DESIRED_TRIM_FILE="$(mktemp)"
LIVE_FILE="$(mktemp)"; LIVE_TRIM_FILE="$(mktemp)"

# meta
jq -n --arg url "$PB_PUBLIC_URL" '{meta:{appName:"PocketBase",appUrl:$url}}' > "$META_FILE"

# storage
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

# backups
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

# desired combined + trimmed for stable compare
jq -s 'add' "$META_FILE" "$STOR_FILE" "$BACK_FILE" > "$DESIRED_FILE"
jq '{meta:{appUrl:.meta.appUrl}, s3, backups}' "$DESIRED_FILE" | jq -S . > "$DESIRED_TRIM_FILE"

# live → trimmed same shape
curl -fsS -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://127.0.0.1:${BOOT_PORT}/api/settings" > "$LIVE_FILE"
jq '{meta:{appUrl:.meta.appUrl}, s3, backups}' "$LIVE_FILE" | jq -S . > "$LIVE_TRIM_FILE"

# patch if needed
if ! diff -q "$DESIRED_TRIM_FILE" "$LIVE_TRIM_FILE" >/dev/null 2>&1; then
  echo "[settings] Applying settings changes…"
  PATCH_OUT="$(mktemp)"; PATCH_CODE=0
  cat "$DESIRED_FILE" | curl -sS -w "%{http_code}" -o "$PATCH_OUT" \
    -X PATCH "http://127.0.0.1:${BOOT_PORT}/api/settings" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
    --data-binary @- > /tmp/pb_patch_code.txt || PATCH_CODE=$?
  HTTP_CODE="$(cat /tmp/pb_patch_code.txt || echo 000)"
  if [ "$PATCH_CODE" -ne 0 ] || [ "$HTTP_CODE" -ge 400 ]; then
    echo "[settings] PATCH failed (HTTP $HTTP_CODE). Response:"; cat "$PATCH_OUT"
    echo "--- bootstrap.log (tail) ---"; tail -n 200 /tmp/pb_bootstrap.log || true

    # Cleanup temp PB & temp admin before exit
    stop_temp
    /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
      admin delete "$TEMP_ADMIN_EMAIL" >/tmp/pb_admin_delete.log 2>&1 || true
    exit 1
  fi
else
  echo "[settings] No settings changes."
fi

# Cleanup temp files
rm -f "$META_FILE" "$STOR_FILE" "$BACK_FILE" "$DESIRED_FILE" "$DESIRED_TRIM_FILE" \
      "$LIVE_FILE" "$LIVE_TRIM_FILE" /tmp/pb_patch_code.txt 2>/dev/null || true

############################################
# Tear down temp PB and remove temp admin
############################################
stop_temp
echo "[temp-admin] Deleting temporary admin: $TEMP_ADMIN_EMAIL"
/app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
  admin delete "$TEMP_ADMIN_EMAIL" >/tmp/pb_admin_delete.log 2>&1 || true
cat /tmp/pb_admin_delete.log || true

echo "[bootstrap] Done."

############################################
# Start the real server
############################################
exec /app/pocketbase $ENCRYPTION_ARG \
  --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
  serve --http 0.0.0.0:8090
