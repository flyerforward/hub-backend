#!/usr/bin/env sh
set -euo pipefail

echo "[boot] entrypoint v7.15 loaded"

############################################
# Env
############################################
: "${PB_ADMIN_EMAIL:?Set PB_ADMIN_EMAIL}"
: "${PB_ADMIN_PASSWORD:?Set PB_ADMIN_PASSWORD}"

# Reset behavior if login fails:
#   all    → delete all admins, then create env admin (last resort path only)
#   single → delete only env email (if present), else delete-all
PB_ADMIN_RESET_MODE="${PB_ADMIN_RESET_MODE:-single}"

# After successful auth, optionally ensure only env admin remains
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

# First-boot restore
PB_RESTORE_FROM_S3="${PB_RESTORE_FROM_S3:-true}"
PB_BACKUP_BUCKET_URL="${PB_BACKUP_BUCKET_URL:-}"

# AWS (Wasabi)
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
export AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
AWS_S3_ENDPOINT="${AWS_S3_ENDPOINT:-}"
if [ -z "$AWS_S3_ENDPOINT" ]; then
  if [ -n "${PB_S3_BACKUPS_ENDPOINT:-}" ]; then AWS_S3_ENDPOINT="$PB_S3_BACKUPS_ENDPOINT"; else AWS_S3_ENDPOINT="$PB_S3_STORAGE_ENDPOINT"; fi
fi

############################################
# Tools & dirs
############################################
apk add --no-cache aws-cli unzip curl jq rsync sqlite coreutils >/dev/null 2>&1 || true
mkdir -p /pb_data /pb_migrations /pb_state
[ -d /app/pb_migrations ] && rsync -a --update /app/pb_migrations/ /pb_migrations/

SETTINGS_SHA_FILE="/pb_state/.settings_sha256"

sql() { sqlite3 /pb_data/data.db "$1"; }
wal_ckpt() { sqlite3 /pb_data/data.db "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true; }

############################################
# Restore (root-files layout only)
############################################
if [ ! -f /pb_data/data.db ] && [ "$PB_RESTORE_FROM_S3" = "true" ] && [ -n "$PB_BACKUP_BUCKET_URL" ]; then
  echo "[restore] No data.db; attempting restore from $PB_BACKUP_BUCKET_URL"
  LATEST_KEY="$(
    aws --endpoint-url "$AWS_S3_ENDPOINT" s3 ls "${PB_BACKUP_BUCKET_URL%/}/" | awk '{print $4,$1,$2}' | sort -k2,3 | tail -n1 | awk '{print $1}'
  )"
  if [ -n "$LATEST_KEY" ]; then
    echo "[restore] Found backup: $LATEST_KEY"
    aws --endpoint-url "$AWS_S3_ENDPOINT" s3 cp "${PB_BACKUP_BUCKET_URL%/}/${LATEST_KEY}" /tmp/pb_backup.zip
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
    echo "[restore] No backups found; starting fresh."
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

  # 1) Does env admin exist?
  ESC_EMAIL="$(printf "%s" "$PB_ADMIN_EMAIL" | sed "s/'/''/g")"
  EXISTS="$(sql "SELECT COUNT(*) FROM _admins WHERE email='$ESC_EMAIL';" 2>/dev/null || echo 0)"

  if [ "${EXISTS:-0}" -gt 0 ]; then
    echo "[admin] Env admin exists → attempting password update (no delete)."
    /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
      admin update "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" >/tmp/pb_admin_update.log 2>&1 || true
    echo "[admin] update output:"; cat /tmp/pb_admin_update.log || true

    # Re-test auth
    start_temp
    AUTH_JSON="$(try_auth)"
    ADMIN_TOKEN="$(echo "$AUTH_JSON" | jq -r .token 2>/dev/null || echo "")"
    if [ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ]; then
      echo "[auth] Auth succeeded after update."
    else
      echo "[admin] Update didn’t fix it → deleting the admin row and recreating."
      stop_temp
      /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
        admin delete "$PB_ADMIN_EMAIL" >/tmp/pb_admin_delete.log 2>&1 || true
      # Verify deletion; if row still there, hard-delete via SQLite
      COUNT_AFTER_CLI="$(sql "SELECT COUNT(*) FROM _admins WHERE email='$ESC_EMAIL';" 2>/dev/null || echo 0)"
      if [ "$COUNT_AFTER_CLI" -gt 0 ]; then
        echo "[admin] CLI delete didn’t remove row → deleting with SQLite."
        sql "DELETE FROM _admins WHERE email='$ESC_EMAIL';"
      fi
      wal_ckpt

      echo "[admin] Creating env admin ${PB_ADMIN_EMAIL}"
      /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
        admin create "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" >/tmp/pb_admin_create.log 2>&1 || true
      echo "[admin] create output:"; cat /tmp/pb_admin_create.log || true

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
    # Optionally clean other admins depending on reset mode
    if [ "$PB_ADMIN_RESET_MODE" = "all" ]; then
      for em in $(sql "SELECT email FROM _admins;"); do
        echo "[admin] Deleting: $em"
        /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
          admin delete "$em" >/tmp/pb_admin_delete.log 2>&1 || true
      done
      wal_ckpt
    fi

    /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
      admin create "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" >/tmp/pb_admin_create.log 2>&1 || true
    echo "[admin] create output:"; cat /tmp/pb_admin_create.log || true

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
    # refresh token (not strictly needed)
    AUTH_JSON="$(try_auth)"
    ADMIN_TOKEN="$(echo "$AUTH_JSON" | jq -r .token 2>/dev/null || echo "")"
  fi
fi

############################################
# Settings: hash + PATCH only if changed
############################################
META_FILE="$(mktemp)"; STOR_FILE="$(mktemp)"; BACK_FILE="$(mktemp)"
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
else echo '{}' > "$STOR_FILE"; fi

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
else echo '{}' > "$BACK_FILE"; fi

DESIRED_FILE="$(mktemp)"
jq -s 'add' "$META_FILE" "$STOR_FILE" "$BACK_FILE" > "$DESIRED_FILE"
DESIRED_TRIM_FILE="$(mktemp)"
jq '{meta:{appUrl:.meta.appUrl}, s3, backups}' "$DESIRED_FILE" | jq -S . > "$DESIRED_TRIM_FILE"
DESIRED_SHA="$(sha256sum "$DESIRED_TRIM_FILE" | awk '{print $1}')"
PREV_SHA="$(cat "$SETTINGS_SHA_FILE" 2>/dev/null || echo "")"

if [ "$DESIRED_SHA" != "$PREV_SHA" ]; then
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
  echo "$DESIRED_SHA" > "$SETTINGS_SHA_FILE"
else
  echo "[settings] No settings changes."
fi

# Cleanup temp resources, start real server
rm -f "$META_FILE" "$STOR_FILE" "$BACK_FILE" "$DESIRED_FILE" "$DESIRED_TRIM_FILE" /tmp/pb_patch_code.txt 2>/dev/null || true
stop_temp
echo "[bootstrap] Done."

exec /app/pocketbase $ENCRYPTION_ARG \
  --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
  serve --http 0.0.0.0:8090
