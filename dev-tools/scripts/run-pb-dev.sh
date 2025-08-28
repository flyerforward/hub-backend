#!/usr/bin/env bash
set -euo pipefail

# --- find the repo root no matter where this script is called from ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  : # REPO_ROOT set by git
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
fi

# --- locations (absolute) ---
PB_DIR="$REPO_ROOT/dev-tools/.pocketbase-dev"
PB_BIN="$PB_DIR/pocketbase"
PB_DATA="$PB_DIR/pb_data"        # <— persistent local dev database lives here
PB_MIG="$REPO_ROOT/pb_migrations"
PB_HOOKS="$REPO_ROOT/pb_hooks"

# --- optional: auto-download if missing (comment out if you don't want this) ---
if [[ ! -x "$PB_BIN" ]]; then
  echo "[run] PocketBase binary not found at $PB_BIN"
  if [[ -x "$REPO_ROOT/scripts/dev/get-pocketbase.sh" ]]; then
    echo "[run] Attempting auto-download..."
    bash "$REPO_ROOT/scripts/dev/get-pocketbase.sh"
  fi
fi

# --- sanity checks ---
[[ -x "$PB_BIN" ]] || { echo "Error: PocketBase not found or not executable at $PB_BIN"; exit 1; }
mkdir -p "$PB_DATA"  # ensure data dir exists
[[ -d "$PB_MIG" ]] || echo "[warn] $PB_MIG not found (continuing)"
[[ -d "$PB_HOOKS" ]] || echo "[warn] $PB_HOOKS not found (continuing)"

# --- allow easy reset: PB_RESET=1 ./scripts/dev/run-pocketbase.sh ---
if [[ "${PB_RESET:-0}" == "1" ]]; then
  echo "[run] PB_RESET=1 → wiping $PB_DATA"
  rm -rf "$PB_DATA"
  mkdir -p "$PB_DATA"
fi

# --- port override via env if desired ---
PB_PORT="${PB_PORT:-8090}"

echo "[run] bin:    $PB_BIN"
echo "[run] dir:    $PB_DATA   (persistent local dev DB)"
echo "[run] hooks:  $PB_HOOKS"
echo "[run] migs:   $PB_MIG"
echo "[run] http:   0.0.0.0:${PB_PORT}"

# --- run pocketbase with absolute paths (cwd no longer matters) ---
exec "$PB_BIN" serve \
  --http "0.0.0.0:${PB_PORT}" \
  --dir "$PB_DATA" \
  --migrationsDir "$PB_MIG" \
  --hooksDir "$PB_HOOKS"
