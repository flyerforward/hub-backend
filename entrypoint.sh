#!/usr/bin/env sh
set -euo pipefail

[ "${PB_DEBUG:-false}" = "true" ] && set -x

echo "[boot] entrypoint v7.23 (stateless, no PB_BACKUP_BUCKET_URL, per-op AWS creds) loaded"

############################################
# Env (required)
############################################
: "${PB_ADMIN_EMAIL:?Set PB_ADMIN_EMAIL}"
: "${PB_ADMIN_PASSWORD:?Set PB_ADMIN_PASSWORD}"

PB_ADMIN_RESET_MODE="${PB_ADMIN_RESET_MODE:-single}"
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

# S3 backups (PocketBase cron + explicit restore)
PB_S3_BACKUPS_ENABLED="${PB_S3_BACKUPS_ENABLED:-true}"
PB_S3_BACKUPS_BUCKET="${PB_S3_BACKUPS_BUCKET:-}"
PB_S3_BACKUPS_REGION="${PB_S3_BACKUPS_REGION:-}"
PB_S3_BACKUPS_ENDPOINT="${PB_S3_BACKUPS_ENDPOINT:-}"
PB_S3_BACKUPS_ACCESS_KEY="${PB_S3_BACKUPS_ACCESS_KEY:-}"
PB_S3_BACKUPS_SECRET="${PB_S3_BACKUPS_SECRET:-}"
PB_S3_BACKUPS_FORCE_PATH_STYLE="${PB_S3_BACKUPS_FORCE_PATH_STYLE:-false}"
PB_BACKUPS_CRON="${PB_BACKUPS_CRON:-0 3 * * *}"
PB_BACKUPS_MAX_KEEP="${PB_BACKUPS_MAX_KEEP:-7}"

# Explicit restore selector (filename under backups bucket, or full s3:// URL)
PB_RESTORE_OBJECT="${PB_RESTORE_OBJECT:-}"

# Compute a consistent escaped admin email once
ESC_EMAIL="$(printf "%s" "$PB_ADMIN_EMAIL" | sed "s/'/''/g")"

############################################
# Tools & dirs
############################################
apk add --no-cache aws-cli unzip curl jq rsync sqlite coreutils diffutils >/dev/null 2>&1 || true
mkdir -p /pb_data /pb_migrations
[ -d /app/pb_migrations ] && rsync -a --update /app/pb_migrations/ /pb_migrations/

sql() { sqlite3 /pb_data/data.db "$1"; }
wal_ckpt() { sqlite3 /pb_data/data.db "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true; }
vacuum_db() { sqlite3 /pb_data/data.db "VACUUM;" >/dev/null 2>&1 || true; }

############################################
# Backups S3 helpers (per-op AWS creds)
############################################
# Prefer explicit "backups" values; fall back to "storage" if not provided.
BK_BUCKET="${PB_S3_BACKUPS_BUCKET:-$PB_S3_STORAGE_BUCKET}"
BK_REGION="${PB_S3_BACKUPS_REGION:-$PB_S3_STORAGE_REGION}"
BK_ENDPOINT="${PB_S3_BACKUPS_ENDPOINT:-$PB_S3_STORAGE_ENDPOINT}"
BK_AK="${PB_S3_BACKUPS_ACCESS_KEY:-$PB_S3_STORAGE_ACCESS_KEY}"
BK_SK="${PB_S3_BACKUPS_SECRET:-$PB_S3_STORAGE_SECRET}"

aws_bk() {
  AWS_ACCESS_KEY_ID="$BK_AK" AWS_SECRET_ACCESS_KEY="$BK_SK" AWS_REGION="$BK_REGION" \
    aws --endpoint-url "$BK_ENDPOINT" "$@"
}

_s3_object_exists() {
  aws_bk s3 ls "$1" >/dev/null 2>&1
}

############################################
# Restore helpers
############################################
_restore_from_zip_any_layout() {
  # Extracts ZIP, finds the folder that contains data.db, rsyncs its contents into /pb_data
  local zip_path="$1"
  local tmpdir="/tmp/pb_restore"
  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"

  unzip -o "$zip_path" -d "$tmpdir" >/dev/null

  local data_path
  data_path="$(find "$tmpdir" -maxdepth 4 -type f -name 'data.db' | head -n1 || true)"
  if [ -z "$data_path" ]; then
    echo "[restore] ERROR: data.db not found in archive."
    rm -rf "$zip_path" "$tmpdir"
    return 1
  fi

  local src_dir
  src_dir="$(dirname "$data_path")"
  echo "[restore] Found data root: $src_dir"

  rsync -a --delete "$src_dir"/ /pb_data/

  rm -rf "$zip_path" "$tmpdir"
  return 0
}

############################################
# Always restore when PB_RESTORE_OBJECT is set
############################################
echo "[env] PB_RESTORE_OBJECT=${PB_RESTORE_OBJECT:-<unset>}"
if [ -n "$PB_RESTORE_OBJECT" ]; then
  # Build full URL if needed (we no longer use PB_BACKUP_BUCKET_URL)
  if printf "%s" "$PB_RESTORE_OBJECT" | grep -q '^s3://'; then
    RESTORE_URL="$PB_RESTORE_OBJECT"
  else
    [ -n "$BK_BUCKET" ] || { echo "[restore] ERROR: Backups bucket not set (PB_S3_BACKUPS_BUCKET or PB_S3_STORAGE_BUCKET)"; exit 1; }
    RESTORE_URL="s3://${BK_BUCKET%/}/$PB_RESTORE_OBJECT"
  fi
  echo "[restore] Resolved: $RESTORE_URL"

  # Verify object exists with backups creds
  if ! _s3_object_exists "$RESTORE_URL"; then
    echo "[restore] ERROR: Object not found: $RESTORE_URL"
    exit 1
  fi

  # Snapshot current data, then empty /pb_data
  if [ -d /pb_data ] && [ "$(ls -A /pb_data 2>/dev/null | wc -l)" -gt 0 ]; then
    TS="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="/pb_data._pre_restore_$TS"
    echo "[restore] Backing up current /pb_data to $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    find /pb_data -mindepth 1 -maxdepth 1 -exec mv {} "$BACKUP_DIR"/ \;
  fi
  mkdir -p /pb_data

  echo "[restore] Downloading archive…"
  aws_bk s3 cp "$RESTORE_URL" /tmp/pb_backup.zip

  echo "[restore] Applying archive (rsync --delete)…"
  if ! _restore_from_zip_any_layout /tmp/pb_backup.zip; then
    echo "[restore] ERROR: Restore failed; attempting to revert previous data."
    if [ -d "${BACKUP_DIR:-}" ]; then
      find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -exec mv {} /pb_data/ \;
      rmdir "$BACKUP_DIR" 2>/dev/null || true
      echo "[restore] Reverted to previous data."
    fi
    exit 1
  fi

  echo "[restore] Forcing WAL checkpoint + VACUUM…"
  wal_ckpt
  vacuum_db

  echo "[restore] Done. Pre-restore snapshot (kept): ${BACKUP_DIR:-<none>}"
else
  if [ ! -f /pb_data/data.db ]; then
    echo "[restore] No PB_RESTORE_OBJECT and no data.db → starting fresh."
  fi
fi

############################################
# Init core + migrations (one-time)
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
# Temp PB helpers + login test
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
AUTH_BODY="$(jq -n --arg id "$PB_ADMIN_EMAIL" --arg pw "$PB_ADMIN_PASSWORD" '{identity:$id, password:$pw}')"
try_auth() {
  curl -sS -X POST "http://127.0.0.1:${BOOT_PORT}/api/admins/auth-with-password" \
    -H "Content-Type: application/json" --data-binary "$AUTH_BODY" || true
}

echo "[auth] Starting temp PB for login test…"
start_temp
AUTH_JSON="$(try_auth)"
ADMIN_TOKEN="$(echo "$AUTH_JSON" | jq -r .token 2>/dev/null || echo "")"

if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
  echo "[auth] Login failed → repairing admin in-place if possible."
  stop_temp

  EXISTS="$(sql "SELECT COUNT(*) FROM _admins WHERE email='$ESC_EMAIL';" 2>/dev/null || echo 0)"

  if [ "${EXISTS:-0}" -gt 0 ]; then
    echo "[admin] Env admin exists → attempting password update (no delete)."
    /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
      admin update "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" >/tmp/pb_admin_update.log 2>&1 || true
    echo "[admin] update output:"; cat /tmp/pb_admin_update.log || true

    start_temp
    AUTH_JSON="$(try_auth)"
    ADMIN_TOKEN="$(echo "$AUTH_JSON" | jq -r .token 2>/dev/null || echo "")"
    if [ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ]; then
      echo "[auth] Auth succeeded after update."
    else
      echo "[admin] Update didn’t fix it → deleting and recreating admin."
      stop_temp
      /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
        admin delete "$PB_ADMIN_EMAIL" >/tmp/pb_admin_delete.log 2>&1 || true
      COUNT_AFTER_CLI="$(sql "SELECT COUNT(*) FROM _admins WHERE email='$ESC_EMAIL';" 2>/dev/null || echo 0)"
      if [ "$COUNT_AFTER_CLI" -gt 0 ]; then
        sql "DELETE FROM _admins WHERE email='$ESC_EMAIL';"
      fi
      wal_ckpt
      echo "[admin] Creating env admin ${PB_ADMIN_EMAIL}"
      /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
        admin create "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" >/tmp/pb_admin_create.log 2>&1 || true
      cat /tmp/pb_admin_create.log || true

      start_temp
      AUTH_JSON="$(try_auth)"
      ADMIN_TOKEN="$(echo "$AUTH_JSON" | jq -r .token 2>/dev/null || echo "")"
      if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
        echo "[auth] Auth still failing after recreate; aborting."; tail -n 200 /tmp/pb_bootstrap.log || true
        stop_temp; exit 1
      fi
    fi

  else
    echo "[admin] Env admin does not exist → creating."
    /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
      admin create "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" >/tmp/pb_admin_create.log 2>&1 || true
    cat /tmp/pb_admin_create.log || true

    start_temp
    AUTH_JSON="$(try_auth)"
    ADMIN_TOKEN="$(echo "$AUTH_JSON" | jq -r .token 2>/dev/null || echo "")"
    if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
      echo "[auth] Auth still failing after create; aborting."; tail -n 200 /tmp/pb_bootstrap.log || true
      stop_temp; exit 1
    fi
  fi
else
  echo "[auth] Login test succeeded."
fi

############################################
# Optional: enforce single admin (delete non-env)
############################################
if [ "$PB_ADMIN_ENFORCE_SINGLE" = "true" ]; then
  COUNT="$(sql "SELECT COUNT(*) FROM _admins;")"
  if [ "${COUNT:-0}" -gt 1 ]; then
    echo "[admin] Enforcing single admin: deleting non-env admins."
    stop_temp
    for em in $(sql "SELECT email FROM _admins WHERE email != '$ESC_EMAIL';"); do
      echo "[admin] Deleting: $em"
      /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
        admin delete "$em" >/tmp/pb_admin_delete.log 2>&1 || true
    done
    wal_ckpt
    start_temp
    AUTH_JSON="$(try_auth)"
    ADMIN_TOKEN="$(echo "$AUTH_JSON" | jq -r .token 2>/dev/null || echo "")"
  fi
fi

############################################
# Settings (STATELESS): compare & patch
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

curl -fsS -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://127.0.0.1:${BOOT_PORT}/api/settings" > "$LIVE_FILE"
jq '{meta:{appUrl:.meta.appUrl}, s3, backups}' "$LIVE_FILE" | jq -S . > "$LIVE_TRIM_FILE"

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
    stop_temp; exit 1
  fi
else
  echo "[settings] No settings changes."
fi

rm -f "$META_FILE" "$STOR_FILE" "$BACK_FILE" "$DESIRED_FILE" "$DESIRED_TRIM_FILE" \
      "$LIVE_FILE" "$LIVE_TRIM_FILE" /tmp/pb_patch_code.txt 2>/dev/null || true

stop_temp
echo "[bootstrap] Done."

exec /app/pocketbase $ENCRYPTION_ARG \
  --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
  serve --http 0.0.0.0:8090
