#!/usr/bin/env sh
set -e

# Create writable runtime dirs (these are volumes in Dokploy) 
mkdir -p /work/pb_migrations /pb_data

# Seed runtime migrations once from the image
if [ -z "$(ls -A /work/pb_migrations 2>/dev/null)" ] && [ -d /app/pb_migrations_seed ]; then
  cp -a /app/pb_migrations/. /work/pb_migrations/
fi

# Start PocketBase:
# --dir           : where DB/files go
# --hooksDir      : where JS hooks live
# --migrationsDir : where to read/apply (and auto-generate) migrations
exec /app/pocketbase \
  --dir /pb_data \
  --hooksDir /app/pb_hooks \
  --migrationsDir /work/pb_migrations \
  serve --http 0.0.0.0:8090