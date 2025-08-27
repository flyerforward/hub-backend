#!/usr/bin/env bash
set -euo pipefail

# --- find repo root no matter where script is run from ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  : # got repo root from git
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
fi

# Absolute paths so cwd doesn't matter
PB_DIR="$REPO_ROOT/dev-tools/.pocketbase-dev"
PB_BIN="$PB_DIR/pocketbase"

mkdir -p "$PB_DIR"
cd "$PB_DIR"

if [[ -x "$PB_BIN" ]]; then
  echo "PocketBase already present at $PB_BIN"
  exit 0
fi

# --- load config.env from repo root if present (export all vars while sourcing) ---
CONFIG_FILE="$REPO_ROOT/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  . "$CONFIG_FILE"
  set +a
fi

echo "Downloading PocketBase v$PB_VERSION to $PB_DIR ..."
curl -L -o pb.zip \
  "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_amd64.zip"

unzip -o pb.zip
rm -f pb.zip
chmod +x "$PB_BIN"

echo "PocketBase ready at $PB_BIN"
