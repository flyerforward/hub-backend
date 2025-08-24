#!/usr/bin/env sh
set -e

# Create runtime migrations + data directories
mkdir -p /pb_migrations /pb_data

# Always sync repo migrations into runtime before starting PB
rsync -a --update /app/pb_migrations/ /pb_migrations/

# Start PocketBase
exec /app/pocketbase \
  --dir /pb_data \
  --hooksDir /app/pb_hooks \
  --migrationsDir /pb_migrations \
  serve --http 0.0.0.0:8090