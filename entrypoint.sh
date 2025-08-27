#!/usr/bin/env sh
set -euo pipefail
[ "${PB_DEBUG:-false}" = "true" ] && set -x

echo "[boot] entrypoint v8.3 (pb_data migrations, restore-aware gate, JSON via c.text, schema-locked admin UI)"

############################################
# Env (no admin creds needed)
############################################
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
mkdir -p /pb_data /app/pb_hooks /pb_data/pb_migrations

sql() { sqlite3 /pb_data/data.db "$1"; }
wal_ckpt() { sqlite3 /pb_data/data.db "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true; }

############################################
# Restore-aware schema gate with pb_data migrations
############################################

_hash_dir() {
  # hash concatenated *.js (assumes no spaces in filenames)
  local d="$1"
  local files
  files="$(find "$d" -type f -name '*.js' | sort 2>/dev/null || true)"
  if [ -z "$files" ]; then
    echo "no_migrations"
  else
    # shellcheck disable=SC2086
    cat $files | sha256sum | awk '{print $1}'
  fi
}
_escape_json() {
  # escape for JSON string literal (backslash/quote/newlines)
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r//g' -e ':a;N;$!ba;s/\n/\\n/g'
}

image_dir="/app/pb_migrations"
data_dir="/pb_data/pb_migrations"

IMG_HASH="$(_hash_dir "$image_dir")"
DATA_HASH="$(_hash_dir "$data_dir")"

LAST_IMG_FILE="/pb_data/.last_img_mig_hash"
if [ -f "$LAST_IMG_FILE" ]; then
  LAST_IMG_HASH="$(cat "$LAST_IMG_FILE" 2>/dev/null || true)"
else
  LAST_IMG_HASH="$IMG_HASH"
  printf '%s\n' "$LAST_IMG_HASH" > "$LAST_IMG_FILE"
fi

# latched gate persists across restarts until reconciled
LATCH_FILE="/pb_data/.mig_gate_latched"
GATED=0; [ -f "$LATCH_FILE" ] && GATED=1

# auto-detect a restore: data hash changed but image hash same as last boot
if [ "$DATA_HASH" != "$IMG_HASH" ] && [ "$LAST_IMG_HASH" = "$IMG_HASH" ]; then
  GATED=1
  printf '1\n' > "$LATCH_FILE"
  echo "[gate] RESTORE detected (image unchanged, pb_data migrations changed)."
fi

# build admin gate hook and decide MIG_DIR
HOOK="/app/pb_hooks/admin_schema_gate.pb.js"
TMP_HOOK="$(mktemp)"

if [ "$GATED" -eq 1 ] && [ "$DATA_HASH" != "$IMG_HASH" ]; then
  # RESTORE path: DO NOT overwrite restored migrations; block admin UI/API with helpful JSON
  LAST_FILE="$(ls -1 "$data_dir" 2>/dev/null | sort | tail -n1 || true)"
  PREVIEW=""
  if [ -n "$LAST_FILE" ] && [ -f "$data_dir/$LAST_FILE" ]; then
    PREVIEW="$(head -c 16000 "$data_dir/$LAST_FILE" | _escape_json || true)"
  fi
  cat >"$TMP_HOOK" <<EOF
// auto-generated: schema mismatch gate (RESTORE latched)
(function(){
  function deny(c){
    var body = {
      code: "schema_mismatch",
      message: "This database was restored. The migrations in /pb_data/pb_migrations differ from the running image. Deploy a build whose migrations match 'expected_schema' OR copy the restored migrations into your repo and redeploy.",
      expected_schema: "$DATA_HASH",
      running_schema: "$IMG_HASH",
      last_restored_migration: "$LAST_FILE",
      last_restored_migration_preview: "$PREVIEW"
    };
    try { return c.text(JSON.stringify(body), 409); } catch (_){}
    return;
  }
  try{ routerAdd("GET","/_/*",deny);}catch(_){}
  try{ routerAdd("HEAD","/_/*",deny);}catch(_){}
  ;["GET","POST","PUT","PATCH","DELETE"].forEach(function(m){
    try{ routerAdd(m,"/api/admins/*",deny);}catch(_){}
  });
})();
EOF
  echo "[gate] GATED: using RESTORED migrations at $data_dir; Admin UI/API blocked."
  MIG_DIR="$data_dir"
else
  # normal or reconciled: sync image -> data and allow admin
  echo "// admin schema gate: no mismatch" >"$TMP_HOOK"
  rsync -a --delete "$image_dir"/ "$data_dir"/
  MIG_DIR="$data_dir"

  # clear latch if reconciled
  if [ "$(_hash_dir "$data_dir")" = "$IMG_HASH" ] && [ -f "$LATCH_FILE" ]; then
    rm -f "$LATCH_FILE"
    echo "[gate] Reconciled. Gate latch cleared."
  fi
fi

mv -f "$TMP_HOOK" "$HOOK"
printf '%s\n' "$IMG_HASH" > "$LAST_IMG_FILE"
printf '%s\n' "$(_hash_dir "$data_dir")" > /pb_data/.schema_hash

############################################
# Schema-lock hook: block collection create/update/delete in Admin UI
############################################
HOOK_TMP="$(mktemp)"
cat >"$HOOK_TMP" <<'EOF'
(function(){
  function deny(c) {
    var body = { code: "schema_locked", message: "Schema/config changes are disabled in this environment." };
    try { return c.text(JSON.stringify(body), 403); } catch (_){}
    return;
  }
  routerAdd("POST",   "/api/collections",           deny);
  routerAdd("PATCH",  "/api/collections/:id",       deny);
  routerAdd("DELETE", "/api/collections/:id",       deny);
  routerAdd("POST",   "/api/collections/import",    deny);
  routerAdd("POST",   "/api/collections/export",    deny);
  routerAdd("POST",   "/api/collections/truncate",  deny);
})();
EOF
mv -f "$HOOK_TMP" /app/pb_hooks/disable_collections_changes.pb.js
echo "[hooks] Wrote /app/pb_hooks/disable_collections_changes.pb.js"

############################################
# Init core + migrations (one-time quick boot)
############################################
INIT_PORT=8097
echo "[init] Starting PB once on :${INIT_PORT}…"
/app/pocketbase $ENCRYPTION_ARG --dev --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir "$MIG_DIR" \
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
# Temp PB helpers (only used if not gated)
############################################
BOOT_PORT=8099
start_temp() {
  /app/pocketbase $ENCRYPTION_ARG --dev --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir "$MIG_DIR" \
    serve --http 127.0.0.1:${BOOT_PORT} >/tmp/pb_bootstrap.log 2>&1 &
  PB_PID=$!
  for i in $(seq 1 120); do
    sleep 0.25
    if curl -fsS "http://127.0.0.1:${BOOT_PORT}/api/health" >/dev/null 2>&1; then return 0; fi
  done
  echo "[bootstrap] PB failed to start"; tail -n 200 /tmp/pb_bootstrap.log || true; return 1
}
stop_temp() { kill $PB_PID 2>/dev/null || true; wait $PB_PID 2>/dev/null || true; }
auth_token() {
  local email="$1" pw="$2"
  local body; body="$(jq -n --arg id "$email" --arg pw "$pw" '{identity:$id, password:$pw}')"
  curl -sS -X POST "http://127.0.0.1:${BOOT_PORT}/api/admins/auth-with-password" \
    -H "Content-Type: application/json" --data-binary "$body" | jq -r '.token // empty'
}

############################################
# Track existing admins BEFORE we create temp (might be zero-admin)
############################################
EXISTING_COUNT="$(sql "SELECT COUNT(*) FROM _admins;" 2>/dev/null || echo 0)"
echo "[temp-admin] Pre-existing admins: ${EXISTING_COUNT:-0}"

############################################
# Create temp admin + apply settings (SKIPPED if gated by restore)
############################################
if [ "$GATED" -eq 1 ]; then
  echo "[bootstrap] Restore-latched → skipping temp-admin + settings apply (admin endpoints are gated)."
else
  RANDHEX="$(head -c16 /dev/urandom | od -An -t x1 | tr -d ' \n')"
  TEMP_ADMIN_EMAIL="admin-${RANDHEX}@service.local"
  TEMP_ADMIN_PASSWORD="$(head -c24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c32)"
  ESC_TEMP_EMAIL="$(printf "%s" "$TEMP_ADMIN_EMAIL" | sed "s/'/''/g")"

  # Collision check (ultra unlikely)
  EXISTS="$(sql "SELECT COUNT(*) FROM _admins WHERE email='${ESC_TEMP_EMAIL}';" 2>/dev/null || echo 0)"
  if [ "${EXISTS:-0}" -gt 0 ]; then
    RANDHEX="$(head -c16 /dev/urandom | od -An -t x1 | tr -d ' \n')"
    TEMP_ADMIN_EMAIL="admin-${RANDHEX}@service.local"
    TEMP_ADMIN_PASSWORD="$(head -c24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c32)"
    ESC_TEMP_EMAIL="$(printf "%s" "$TEMP_ADMIN_EMAIL" | sed "s/'/''/g")"
  fi

  echo "[temp-admin] Creating temporary admin: $TEMP_ADMIN_EMAIL"
  /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir "$MIG_DIR" \
    admin create "$TEMP_ADMIN_EMAIL" "$TEMP_ADMIN_PASSWORD" >/tmp/pb_admin_create.log 2>&1 || true
  cat /tmp/pb_admin_create.log || true

  echo "[bootstrap] Starting temp PB for settings apply…"
  start_temp

  ADMIN_TOKEN="$(auth_token "$TEMP_ADMIN_EMAIL" "$TEMP_ADMIN_PASSWORD")"
  if [ -z "$ADMIN_TOKEN" ]; then
    echo "[temp-admin] ERROR: could not authenticate temp admin."
    tail -n 200 /tmp/pb_bootstrap.log || true
    stop_temp
    # best-effort cleanup via SQL (in case it's the only admin)
    sql "DELETE FROM _admins WHERE email='${ESC_TEMP_EMAIL}';" || true
    wal_ckpt
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

  # desired combined + trimmed for compare
  jq -s 'add' "$META_FILE" "$STOR_FILE" "$BACK_FILE" > "$DESIRED_FILE"
  jq '{meta:{appUrl:.meta.appUrl}, s3, backups}' "$DESIRED_FILE" | jq -S . > "$DESIRED_TRIM_FILE"

  # live → same shape
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
      stop_temp
      # clean up temp admin safely (in case it's the only admin)
      if [ "${EXISTING_COUNT:-0}" -gt 0 ]; then
        /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir "$MIG_DIR" \
          admin delete "$TEMP_ADMIN_EMAIL" >/tmp/pb_admin_delete.log 2>&1 || true
      else
        sql "DELETE FROM _admins WHERE email='${ESC_TEMP_EMAIL}';" || true
        wal_ckpt
      fi
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
  if [ "${EXISTING_COUNT:-0}" -gt 0 ]; then
    echo "[temp-admin] Deleting temporary admin via CLI (other admins exist)."
    /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir "$MIG_DIR" \
      admin delete "$TEMP_ADMIN_EMAIL" >/tmp/pb_admin_delete.log 2>&1 || true
    cat /tmp/pb_admin_delete.log || true
  else
    echo "[temp-admin] Removing the only admin via direct SQL to leave zero-admin state."
    sql "DELETE FROM _admins WHERE email='${ESC_TEMP_EMAIL}';" || true
    wal_ckpt
  fi
fi

echo "[bootstrap] Done."

############################################
# Start the real server (always use pb_data migrations dir)
############################################
exec /app/pocketbase $ENCRYPTION_ARG \
  --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir "/pb_data/pb_migrations" \
  serve --http 0.0.0.0:8090
