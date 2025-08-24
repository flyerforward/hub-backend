#!/usr/bin/env sh
set -euo pipefail

# --------------------------
# Required/optional env vars
# --------------------------

# --- Admin bootstrap (required for first run if no admin exists) ---
: "${PB_ADMIN_EMAIL:?Set PB_ADMIN_EMAIL}"
: "${PB_ADMIN_PASSWORD:?Set PB_ADMIN_PASSWORD}"

# Optional: encrypt secrets stored in PB settings (recommended)
PB_ENCRYPTION="${PB_ENCRYPTION:-}"
ENCRYPTION_ARG=""
[ -n "$PB_ENCRYPTION" ] && ENCRYPTION_ARG="--encryptionEnv PB_ENCRYPTION"

# Public URL of your PB instance (for settings/meta & links)
PB_PUBLIC_URL="${PB_PUBLIC_URL:-http://127.0.0.1:8090}"

# --- S3 for FILE STORAGE (uploads) ---
PB_S3_STORAGE_ENABLED="${PB_S3_STORAGE_ENABLED:-true}"
PB_S3_STORAGE_BUCKET="${PB_S3_STORAGE_BUCKET:-}"
PB_S3_STORAGE_REGION="${PB_S3_STORAGE_REGION:-}"
PB_S3_STORAGE_ENDPOINT="${PB_S3_STORAGE_ENDPOINT:-}"
PB_S3_STORAGE_ACCESS_KEY="${PB_S3_STORAGE_ACCESS_KEY:-}"
PB_S3_STORAGE_SECRET="${PB_S3_STORAGE_SECRET:-}"
PB_S3_STORAGE_FORCE_PATH_STYLE="${PB_S3_STORAGE_FORCE_PATH_STYLE:-false}"

# --- S3 for BACKUPS (PocketBase scheduled backups) ---
PB_S3_BACKUPS_ENABLED="${PB_S3_BACKUPS_ENABLED:-true}"
PB_S3_BACKUPS_BUCKET="${PB_S3_BACKUPS_BUCKET:-}"
PB_S3_BACKUPS_REGION="${PB_S3_BACKUPS_REGION:-}"
PB_S3_BACKUPS_ENDPOINT="${PB_S3_BACKUPS_ENDPOINT:-}"
PB_S3_BACKUPS_ACCESS_KEY="${PB_S3_BACKUPS_ACCESS_KEY:-}"
PB_S3_BACKUPS_SECRET="${PB_S3_BACKUPS_SECRET:-}"
PB_S3_BACKUPS_FORCE_PATH_STYLE="${PB_S3_BACKUPS_FORCE_PATH_STYLE:-false}"
PB_BACKUPS_CRON="${PB_BACKUPS_CRON:-0 3 * * *}"
PB_BACKUPS_MAX_KEEP="${PB_BACKUPS_MAX_KEEP:-7}"

# --- First-boot restore from S3 backup ZIP (external bucket) ---
PB_RESTORE_FROM_S3="${PB_RESTORE_FROM_S3:-true}"
PB_BACKUP_BUCKET_URL="${PB_BACKUP_BUCKET_URL:-}"    # e.g. s3://bucket or s3://bucket/prefix

# AWS CLI creds/region for restore (you already set these)
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"

# Ensure the AWS CLI hits Wasabi (or other S3-compatible) not AWS S3.
# Prefer explicit AWS_S3_ENDPOINT; else fall back to PB_S3_BACKUPS_ENDPOINT; else PB_S3_STORAGE_ENDPOINT.
AWS_S3_ENDPOINT="${AWS_S3_ENDPOINT:-}"
if [ -z "$AWS_S3_ENDPOINT" ]; then
  if [ -n "$PB_S3_BACKUPS_ENDPOINT" ]; then
    AWS_S3_ENDPOINT="$PB_S3_BACKUPS_ENDPOINT"
  else
    AWS_S3_ENDPOINT="$PB_S3_STORAGE_ENDPOINT"
  fi
fi

# --------------------------
# Paths & initial sync
# --------------------------
mkdir -p /pb_data /pb_migrations

# Keep repo migrations in sync with runtime (no delete to preserve any runtime-generated files)
if [ -d /app/pb_migrations ]; then
  rsync -a --update /app/pb_migrations/ /pb_migrations/
fi

# --------------------------
# First-boot: auto-restore from S3 if data.db is missing
# --------------------------
if [ ! -f /pb_data/data.db ] && [ "$PB_RESTORE_FROM_S3" = "true" ] && [ -n "$PB_BACKUP_BUCKET_URL" ]; then
  echo "[restore] No data.db; attempting restore from $PB_BACKUP_BUCKET_URL"
  export AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

  # List newest object in the given bucket/prefix using the proper endpoint
  LATEST_KEY="$(
    aws --endpoint-url "$AWS_S3_ENDPOINT" s3 ls "${PB_BACKUP_BUCKET_URL%/}/" \
    | awk '{print $4,$1,$2}' | sort -k2,3 | tail -n1 | awk '{print $1}'
  )"

  if [ -n "$LATEST_KEY" ]; then
    echo "[restore] Found backup: $LATEST_KEY"
    aws --endpoint-url "$AWS_S3_ENDPOINT" s3 cp \
      "${PB_BACKUP_BUCKET_URL%/}/${LATEST_KEY}" /tmp/pb_backup.zip
    apk add --no-cache unzip >/dev/null 2>&1 || true
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

# --------------------------
# Ensure an admin exists
# --------------------------
if ! /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations admin list >/dev/null 2>&1; then
  echo "[admin] Creating admin if missing"
  /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations \
    admin create "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" || true
fi

# --------------------------
# Headless Settings bootstrap (S3 storage + backups)
# Start PB on a loopback port, configure via API, then stop it.
# --------------------------
apk add --no-cache curl jq >/dev/null 2>&1 || true
BOOT_PORT=8099
echo "[bootstrap] Starting temporary PB on :${BOOT_PORT} for settings..."
/app/pocketbase $ENCRYPTION_ARG \
  --dir /pb_data \
  --hooksDir /app/pb_hooks \
  --migrationsDir /pb_migrations \
  serve --http 127.0.0.1:${BOOT_PORT} >/tmp/pb_bootstrap.log 2>&1 &
PB_PID=$!

# Wait until health endpoint responds
for i in $(seq 1 60); do
  sleep 0.25
  if curl -fsS "http://127.0.0.1:${BOOT_PORT}/api/health" >/dev/null 2>&1; then break; fi
  [ "$i" -eq 60 ] && echo "[bootstrap] PB failed to start" && cat /tmp/pb_bootstrap.log && exit 1
done

# Get admin token
ADMIN_TOKEN="$(curl -fsS -X POST "http://127.0.0.1:${BOOT_PORT}/api/admins/auth-with-password" \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"$PB_ADMIN_EMAIL\",\"password\":\"$PB_ADMIN_PASSWORD\"}" \
  | jq -r .token)"

if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
  echo "[bootstrap] Failed to obtain admin token"
  cat /tmp/pb_bootstrap.log || true
  kill $PB_PID; wait $PB_PID 2>/dev/null || true
  exit 1
fi

# Build JSON for S3 storage & backups
STORAGE_JSON="{}"
if [ "$PB_S3_STORAGE_ENABLED" = "true" ]; then
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
if [ "$PB_S3_BACKUPS_ENABLED" = "true" ]; then
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

SETTINGS_BODY="$(jq -n \
  --arg url "$PB_PUBLIC_URL" \
  --argjson s3 "${STORAGE_JSON}" \
  --argjson backups "${BACKUPS_JSON}" \
  '{meta:{appName:"PocketBase",appUrl:$url},
    s3:$s3,
    backups:$backups
  }')"

# PATCH /api/settings
echo "$SETTINGS_BODY" | curl -fsS -X PATCH "http://127.0.0.1:${BOOT_PORT}/api/settings" \
  -H "Authorization: $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @- >/dev/null

# Test S3 connections (optional)
if [ "$PB_S3_STORAGE_ENABLED" = "true" ]; then
  curl -fsS -X POST "http://127.0.0.1:${BOOT_PORT}/api/settings/test/s3" \
    -H "Authorization: $ADMIN_TOKEN" -H "Content-Type: application/json" \
    -d '{"filesystem":"storage"}' >/dev/null || true
fi

if [ "$PB_S3_BACKUPS_ENABLED" = "true" ]; then
  curl -fsS -X POST "http://127.0.0.1:${BOOT_PORT}/api/settings/test/s3" \
    -H "Authorization: $ADMIN_TOKEN" -H "Content-Type: application/json" \
    -d '{"filesystem":"backups"}' >/dev/null || true
fi

# Stop temp PB
kill $PB_PID
wait $PB_PID 2>/dev/null || true
echo "[bootstrap] Settings configured."

# --------------------------
# Start the real server
# --------------------------
exec /app/pocketbase $ENCRYPTION_ARG \
  --dir /pb_data \
  --hooksDir /app/pb_hooks \
  --migrationsDir /pb_migrations \
  serve --http 0.0.0.0:8090
