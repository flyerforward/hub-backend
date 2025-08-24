#!/usr/bin/env sh
set -euo pipefail

# --------------------------
# Required env vars (set in Dokploy)
# --------------------------
# Admin bootstrap (only used if no admins exist)
: "${PB_ADMIN_EMAIL:?Set PB_ADMIN_EMAIL}"
: "${PB_ADMIN_PASSWORD:?Set PB_ADMIN_PASSWORD}"

# Encrypt sensitive settings at rest (recommended)
# Provide a strong secret in Dokploy envs, e.g. PB_ENCRYPTION="..." 
PB_ENCRYPTION="${PB_ENCRYPTION:-}"  # optional
ENCRYPTION_ARG=""
[ -n "$PB_ENCRYPTION" ] && ENCRYPTION_ARG="--encryptionEnv PB_ENCRYPTION"

# Public URL (used for Settings.meta.appUrl; adjust to your domain)
PB_PUBLIC_URL="${PB_PUBLIC_URL:-http://127.0.0.1:8090}"

# S3: files storage (user uploads)
PB_S3_STORAGE_ENABLED="${PB_S3_STORAGE_ENABLED:-true}"
PB_S3_STORAGE_BUCKET="${PB_S3_STORAGE_BUCKET:-}"
PB_S3_STORAGE_REGION="${PB_S3_STORAGE_REGION:-}"
PB_S3_STORAGE_ENDPOINT="${PB_S3_STORAGE_ENDPOINT:-}"  # e.g. https://s3.amazonaws.com or https://<region>.digitaloceanspaces.com
PB_S3_STORAGE_ACCESS_KEY="${PB_S3_STORAGE_ACCESS_KEY:-}"
PB_S3_STORAGE_SECRET="${PB_S3_STORAGE_SECRET:-}"
PB_S3_STORAGE_FORCE_PATH_STYLE="${PB_S3_STORAGE_FORCE_PATH_STYLE:-false}"

# S3: backups
PB_S3_BACKUPS_ENABLED="${PB_S3_BACKUPS_ENABLED:-true}"
PB_S3_BACKUPS_BUCKET="${PB_S3_BACKUPS_BUCKET:-}"
PB_S3_BACKUPS_REGION="${PB_S3_BACKUPS_REGION:-}"
PB_S3_BACKUPS_ENDPOINT="${PB_S3_BACKUPS_ENDPOINT:-}"
PB_S3_BACKUPS_ACCESS_KEY="${PB_S3_BACKUPS_ACCESS_KEY:-}"
PB_S3_BACKUPS_SECRET="${PB_S3_BACKUPS_SECRET:-}"
PB_S3_BACKUPS_FORCE_PATH_STYLE="${PB_S3_BACKUPS_FORCE_PATH_STYLE:-false}"
PB_BACKUPS_CRON="${PB_BACKUPS_CRON:-0 3 * * *}"     # nightly 03:00 UTC
PB_BACKUPS_MAX_KEEP="${PB_BACKUPS_MAX_KEEP:-7}"     # keep last 7

# S3 restore (first boot only) – bucket where PB uploads backup ZIPs
PB_RESTORE_FROM_S3="${PB_RESTORE_FROM_S3:-true}"
PB_BACKUP_BUCKET_URL="${PB_BACKUP_BUCKET_URL:-}"    # s3://your-backup-bucket/prefix
AWS_REGION="${AWS_REGION:-us-east-1}"               # for aws cli

# --------------------------
# Paths
# --------------------------
mkdir -p /pb_data /pb_migrations
# Keep repo migrations in sync with runtime, but never delete runtime-only files
rsync -a --update /app/pb_migrations/ /pb_migrations/

# --------------------------
# First-boot: auto-restore pb_data from latest S3 backup
# --------------------------
if [ ! -f /pb_data/data.db ] && [ "$PB_RESTORE_FROM_S3" = "true" ] && [ -n "$PB_BACKUP_BUCKET_URL" ]; then
  echo "[restore] No data.db found; attempting restore from $PB_BACKUP_BUCKET_URL"
  export AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  # pick newest object
  # shellcheck disable=SC2016
  LATEST_KEY="$(aws s3 ls "${PB_BACKUP_BUCKET_URL%/}/" | awk '{print $4,$1,$2}' | sort -k2,3 | tail -n1 | awk '{print $1}')"
  if [ -n "$LATEST_KEY" ]; then
    echo "[restore] Found backup: $LATEST_KEY"
    aws s3 cp "${PB_BACKUP_BUCKET_URL%/}/${LATEST_KEY}" /tmp/pb_backup.zip
    unzip -o /tmp/pb_backup.zip -d /tmp/pb_restore
    if [ -d /tmp/pb_restore/pb_data ]; then
      cp -a /tmp/pb_restore/pb_data/. /pb_data/
      echo "[restore] Restore complete."
    else
      echo "[restore] Unexpected archive layout; skipping."
    fi
    rm -rf /tmp/pb_backup.zip /tmp/pb_restore
  else
    echo "[restore] No backups found; continuing without restore."
  fi
fi

# --------------------------
# Ensure an admin exists (CLI works without the server running)
# If there are no admins, the CLI will create the first one.
# --------------------------
if [ ! -f /pb_data/data.db ] || ! /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations admin list >/dev/null 2>&1; then
  echo "[admin] Creating admin (if none exists)"
  # create returns 0 if created; non-zero if already there (ok)
  /app/pocketbase $ENCRYPTION_ARG --dir /pb_data --migrationsDir /pb_migrations admin create "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" || true
fi

# --------------------------
# Headless Settings bootstrap (S3 storage + auto-backups)
# We start PB on a local port, call the Settings API, then stop it.
# --------------------------
BOOT_PORT=8099
echo "[boot] Starting temporary PB on :${BOOT_PORT} to set settings..."
/app/pocketbase $ENCRYPTION_ARG \
  --dir /pb_data \
  --hooksDir /app/pb_hooks \
  --migrationsDir /pb_migrations \
  serve --http 127.0.0.1:${BOOT_PORT} >/tmp/pb_bootstrap.log 2>&1 &
PB_PID=$!

# wait until it responds
for i in $(seq 1 40); do
  sleep 0.25
  if curl -fsS "http://127.0.0.1:${BOOT_PORT}/api/health" >/dev/null 2>&1; then break; fi
  [ "$i" -eq 40 ] && echo "[boot] PB failed to start for bootstrap" && cat /tmp/pb_bootstrap.log && exit 1
done

# admin auth -> token
ADMIN_TOKEN="$(curl -fsS -X POST "http://127.0.0.1:${BOOT_PORT}/api/admins/auth-with-password" \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"$PB_ADMIN_EMAIL\",\"password\":\"$PB_ADMIN_PASSWORD\"}" \
  | jq -r .token)"

if [ "$ADMIN_TOKEN" = "null" ] || [ -z "$ADMIN_TOKEN" ]; then
  echo "[boot] Failed to obtain admin token"; cat /tmp/pb_bootstrap.log; kill $PB_PID; exit 1
fi

# Build settings payload
STORAGE_JSON="{}"
if [ "$PB_S3_STORAGE_ENABLED" = "true" ]; then
  STORAGE_JSON="$(jq -n --arg b "$PB_S3_STORAGE_BUCKET" --arg r "$PB_S3_STORAGE_REGION" \
    --arg e "$PB_S3_STORAGE_ENDPOINT" --arg ak "$PB_S3_STORAGE_ACCESS_KEY" --arg sk "$PB_S3_STORAGE_SECRET" \
    --argjson fps "$PB_S3_STORAGE_FORCE_PATH_STYLE" \
    '{enabled:true,bucket:$b,region:$r,endpoint:$e,accessKey:$ak,secret:$sk,forcePathStyle:$fps}')"
fi

BACKUPS_JSON="{}"
if [ "$PB_S3_BACKUPS_ENABLED" = "true" ]; then
  BACKUPS_S3="$(jq -n --arg b "$PB_S3_BACKUPS_BUCKET" --arg r "$PB_S3_BACKUPS_REGION" \
    --arg e "$PB_S3_BACKUPS_ENDPOINT" --arg ak "$PB_S3_BACKUPS_ACCESS_KEY" --arg sk "$PB_S3_BACKUPS_SECRET" \
    --argjson fps "$PB_S3_BACKUPS_FORCE_PATH_STYLE" \
    '{enabled:true,bucket:$b,region:$r,endpoint:$e,accessKey:$ak,secret:$sk,forcePathStyle:$fps}')"
  BACKUPS_JSON="$(jq -n --arg cron "$PB_BACKUPS_CRON" --argjson keep "$PB_BACKUPS_MAX_KEEP" --argjson s3 "$BACKUPS_S3" \
    '{cron:$cron,cronMaxKeep:$keep|tonumber,s3:($s3|fromjson)}')"
fi

SETTINGS_BODY="$(jq -n \
  --arg url "$PB_PUBLIC_URL" \
  --argjson s3 "${STORAGE_JSON}" \
  --argjson backups "${BACKUPS_JSON}" \
  '{meta:{appName:"PocketBase",appUrl:$url,senderName:"",senderAddress:""},
    s3:$s3,backups:$backups
  }')"

# PATCH /api/settings
echo "$SETTINGS_BODY" | \
curl -fsS -X PATCH "http://127.0.0.1:${BOOT_PORT}/api/settings" \
  -H "Authorization: $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @- >/dev/null

# Optional: test S3 connections
[ "$PB_S3_STORAGE_ENABLED" = "true" ] && \
  curl -fsS -X POST "http://127.0.0.1:${BOOT_PORT}/api/settings/test/s3" \
    -H "Authorization: $ADMIN_TOKEN" -H "Content-Type: application/json" \
    -d '{"filesystem":"storage"}' >/dev/null || true

[ "$PB_S3_BACKUPS_ENABLED" = "true" ] && \
  curl -fsS -X POST "http://127.0.0.1:${BOOT_PORT}/api/settings/test/s3" \
    -H "Authorization: $ADMIN_TOKEN" -H "Content-Type: application/json" \
    -d '{"filesystem":"backups"}' >/dev/null || true

# stop temp PB
kill $PB_PID
wait $PB_PID 2>/dev/null || true
echo "[boot] Settings configured."

# --------------------------
# Start the real server (public)
# --------------------------
exec /app/pocketbase $ENCRYPTION_ARG \
  --dir /pb_data \
  --hooksDir /app/pb_hooks \
  --migrationsDir /pb_migrations \
  serve --http 0.0.0.0:8090
