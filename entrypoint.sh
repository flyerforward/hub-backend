#!/usr/bin/env sh
set -euo pipefail
[ "${PB_DEBUG:-false}" = "true" ] && set -x

echo "[boot] entrypoint v7.26 (stateless, temp-admin bootstrap, zero-admin supported) loaded"

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
# Auto RESTORE detection + schema-hash gate
############################################

# --- helpers ---
db_sql() { sqlite3 /pb_data/data.db "$1"; }

# 1) IMAGE schema hash from /app/pb_migrations (simple: assumes no spaces)
IMG_FILES="$(find /app/pb_migrations -type f -name '*.js' | sort)"
if [ -n "$IMG_FILES" ]; then
  IMG_SCHEMA_HASH="$(cat $IMG_FILES | sha256sum | awk '{print $1}')"
else
  IMG_SCHEMA_HASH="no_migrations"
fi

# 2) DB schema hash (travels with backups); init on first boot
DB_SCHEMA_FILE="/pb_data/.schema_hash"
if [ -f "$DB_SCHEMA_FILE" ]; then
  DB_SCHEMA_HASH="$(cat "$DB_SCHEMA_FILE" 2>/dev/null || true)"
else
  DB_SCHEMA_HASH="$IMG_SCHEMA_HASH"
  printf '%s\n' "$DB_SCHEMA_HASH" > "$DB_SCHEMA_FILE"
fi

# 3) Last image hash seen at runtime (to tell deploy vs restore automatically)
LAST_IMG_FILE="/pb_data/.last_img_schema_hash"
if [ -f "$LAST_IMG_FILE" ]; then
  LAST_IMG_HASH="$(cat "$LAST_IMG_FILE" 2>/dev/null || true)"
else
  LAST_IMG_HASH="$IMG_SCHEMA_HASH"
  printf '%s\n' "$LAST_IMG_HASH" > "$LAST_IMG_FILE"
fi

# 4) Latch: once a restore is detected, keep gating until reconciled
RESTORE_LATCH_FILE="/pb_data/.restore_latched"
RESTORE_LATCH=0
[ -f "$RESTORE_LATCH_FILE" ] && RESTORE_LATCH=1

# 5) Decide mode
#    - If DB != IMG and image didn't change since last boot -> auto RESTORE detected -> latch
if [ "$DB_SCHEMA_HASH" != "$IMG_SCHEMA_HASH" ] && [ "$LAST_IMG_HASH" = "$IMG_SCHEMA_HASH" ]; then
  RESTORE_LATCH=1
  printf '1\n' > "$RESTORE_LATCH_FILE"
  echo "[schema-gate] Auto-detected RESTORE (image unchanged, DB hash changed). Latching gate."
fi

# 6) Build some helpful metadata for the JSON (last common migration, counts)
#    DB applied migrations (filenames) from _migrations; may not exist on very first boot.
DB_APPLIED=""
if db_sql "SELECT name FROM _migrations LIMIT 1;" >/dev/null 2>&1; then
  DB_APPLIED="$(db_sql "SELECT name FROM _migrations ORDER BY created ASC;")"
fi
# image migrations (basenames)
IMG_LIST="$(for f in $IMG_FILES; do basename "$f"; done)"

# Find last common migration name (longest common prefix of DB_APPLIED within IMG_LIST order)
LAST_COMMON=""
if [ -n "$DB_APPLIED" ] && [ -n "$IMG_LIST" ]; then
  # turn into newline lists
  # shellcheck disable=SC2086
  LAST_COMMON="$(printf '%s\n' $DB_APPLIED | awk 'NF' | while read -r n; do
    echo "$IMG_LIST" | tr ' ' '\n' | grep -xq "$n" && echo "$n" || true
  done | tail -n1)"
fi

DB_COUNT=0; IMG_COUNT=0; UNAPPLIED_COUNT=0
[ -n "$DB_APPLIED" ] && DB_COUNT="$(printf '%s\n' $DB_APPLIED | awk 'NF' | wc -l | tr -d ' ')"
[ -n "$IMG_LIST" ]   && IMG_COUNT="$(printf '%s\n' $IMG_LIST   | awk 'NF' | wc -l | tr -d ' ')"
# unapplied = how many image files aren’t recorded in DB
if [ -n "$IMG_LIST" ]; then
  UNAPPLIED_COUNT="$(for f in $IMG_LIST; do
    printf '%s\n' $DB_APPLIED | awk 'NF' | grep -xq "$f" || echo 1
  done | awk '{s+=$1} END{print s+0}')"
fi

# 7) Generate the gate hook + choose migrations dir
HOOK="/app/pb_hooks/admin_schema_gate.pb.js"
TMP_HOOK="$(mktemp)"

if [ "$RESTORE_LATCH" -eq 1 ] && [ "$DB_SCHEMA_HASH" != "$IMG_SCHEMA_HASH" ]; then
  # RESTORE (latched) → block Admin UI/API and SKIP migrations
  cat >"$TMP_HOOK" <<EOF
// auto-generated: schema mismatch gate (RESTORE latched)
(function(){
  function deny(c){
    var body={
      code:"schema_mismatch",
      message:"This database was restored to a different schema. Deploy a build whose migrations hash matches 'expected_schema', or generate a snapshot migration at the top of your repo that reflects the restored state.",
      expected_schema:"$DB_SCHEMA_HASH",
      running_schema:"$IMG_SCHEMA_HASH",
      last_common_migration:"$LAST_COMMON",
      db_applied_count:$DB_COUNT,
      image_total_count:$IMG_COUNT,
      unapplied_in_image:$UNAPPLIED_COUNT
    };
    try{ return c.json(body,409);}catch(_){}
    try{ return c.json(409,body);}catch(_){}
    return;
  }
  try{ routerAdd("GET","/_/*",deny);}catch(_){}
  try{ routerAdd("HEAD","/_/*",deny);}catch(_){}
  ;["GET","HEAD","POST","PUT","PATCH","DELETE","OPTIONS"].forEach(function(m){
    try{ routerAdd(m,"/api/admins/*",deny);}catch(_){}
  });
})();
EOF
  echo "[schema-gate] GATED (restore-latched): DB=$DB_SCHEMA_HASH IMG=$IMG_SCHEMA_HASH; last_common='$LAST_COMMON'; unapplied=$UNAPPLIED_COUNT"
  MIG_DIR="/app/pb_migrations_off"; mkdir -p "$MIG_DIR"
else
  # Normal deploy (image changed) or reconciled state → allow migrations, clear latch if matched
  echo "// schema gate: normal/reconciled (DB=$DB_SCHEMA_HASH, IMG=$IMG_SCHEMA_HASH)" >"$TMP_HOOK"
  MIG_DIR="/app/pb_migrations"
  if [ "$DB_SCHEMA_HASH" = "$IMG_SCHEMA_HASH" ] && [ -f "$RESTORE_LATCH_FILE" ]; then
    rm -f "$RESTORE_LATCH_FILE"
    echo "[schema-gate] Reconciled → latch cleared."
  fi
fi
mv -f "$TMP_HOOK" "$HOOK"

# 8) Persist "last image seen" for next-boot detection
printf '%s\n' "$IMG_SCHEMA_HASH" > "$LAST_IMG_FILE"

# 9) After migrations run (only when not skipped), refresh the DB schema hash so future backups carry it
#    Call this after your init/bootstrap step applies migrations, or right before final exec if you only run serve once.
if [ "${MIG_DIR:-/app/pb_migrations}" = "/app/pb_migrations" ]; then
  printf '%s\n' "$IMG_SCHEMA_HASH" > "$DB_SCHEMA_FILE"
fi 





























############################################
# Tools & dirs
############################################
apk add --no-cache curl jq sqlite coreutils diffutils rsync >/dev/null 2>&1 || true
mkdir -p /pb_data /pb_migrations /app/pb_hooks
[ -d /app/pb_migrations ] && rsync -a --update /app/pb_migrations/ /pb_migrations/

sql() { sqlite3 /pb_data/data.db "$1"; }
wal_ckpt() { sqlite3 /pb_data/data.db "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true; }

############################################
# Write the disable_collections_changes.pb.js hook file (disable collections changes for production admin UI)
############################################
HOOK_TMP="$(mktemp)"
cat >"$HOOK_TMP" <<'EOF'
function deny(c) {
  const body = { code: "schema_locked", message: "Schema/config changes are disabled in this environment." };
  try { return c.json(body, 403); } catch (_) {}
  try { return c.json(403, body); } catch (_) {}
  try { if (c?.response) { c.response.status = 403; return c.response.json ? c.response.json(body) : undefined; } } catch (_) {}
  return; // last resort
}

// --- Collections schema ops ---
routerAdd("POST",   "/api/collections",        deny);      // create collection
routerAdd("PATCH",  "/api/collections/:id",    deny);      // update collection
routerAdd("DELETE", "/api/collections/:id",    deny);      // delete collection
routerAdd("POST",   "/api/collections/import", deny);
routerAdd("POST",   "/api/collections/export", deny);
routerAdd("POST",   "/api/collections/truncate", deny);
EOF
# Atomic replace to avoid stale content
mv -f "$HOOK_TMP" /app/pb_hooks/disable_collections_changes.pb.js
echo "[hooks] Wrote /app/pb_hooks/disable_collections_changes.js"

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

auth_token() {
  local email="$1" pw="$2"
  local body; body="$(jq -n --arg id "$email" --arg pw "$pw" '{identity:$id, password:$pw}')"
  curl -sS -X POST "http://127.0.0.1:${BOOT_PORT}/api/admins/auth-with-password" \
    -H "Content-Type: application/json" --data-binary "$body" | jq -r '.token // empty'
}

############################################
# Track existing admins BEFORE we create temp
############################################
EXISTING_COUNT="$(sql "SELECT COUNT(*) FROM _admins;" 2>/dev/null || echo 0)"
echo "[temp-admin] Pre-existing admins: ${EXISTING_COUNT:-0}"

############################################
# Create temporary service admin
############################################
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
/app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
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
    # clean up temp admin safely (use SQL if it's the only one)
    if [ "${EXISTING_COUNT:-0}" -gt 0 ]; then
      /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
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
  /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
    admin delete "$TEMP_ADMIN_EMAIL" >/tmp/pb_admin_delete.log 2>&1 || true
  cat /tmp/pb_admin_delete.log || true
else
  echo "[temp-admin] Removing the only admin via direct SQL to leave zero-admin state."
  sql "DELETE FROM _admins WHERE email='${ESC_TEMP_EMAIL}';" || true
  wal_ckpt
fi

echo "[bootstrap] Done."

############################################
# Start the real server
############################################
exec /app/pocketbase $ENCRYPTION_ARG \
  --dir /pb_data --hooksDir /app/pb_hooks --migrationsDir /pb_migrations \
  serve --http 0.0.0.0:8090
