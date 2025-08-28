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
CONFIG_FILE="$REPO_ROOT/config.env"

mkdir -p "$PB_DIR"
cd "$PB_DIR"

# --- prerequisites ---
command -v curl >/dev/null 2>&1 || { echo "[get-pb-dev] ERROR: curl is required"; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "[get-pb-dev] ERROR: unzip is required"; exit 1; }

# --- load config.env from repo root ---
if [[ -f "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
else
  echo "[get-pb-dev] ERROR: config.env not found at repo root: $CONFIG_FILE"
  exit 1
fi

: "${PB_VERSION:?PB_VERSION must be set in config.env}"

# Helper to read the version from an existing binary
get_bin_version() {
  local out ver
  out="$("$PB_BIN" --version 2>/dev/null || true)"
  # Examples:
  # "PocketBase version 0.22.14 (linux/amd64)"
  # "version 0.21.16"
  ver="$(printf '%s' "$out" | awk '{for(i=1;i<=NF;i++){if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+$/){print $i; exit}}}')"
  printf '%s' "${ver:-}"
}

download_pb() {
  echo "[get-pb-dev] Downloading PocketBase v$PB_VERSION to $PB_DIR ..."
  curl -fL -o pb.zip \
    "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_amd64.zip"
  unzip -o pb.zip
  rm -f pb.zip
  chmod +x "$PB_BIN"
  echo "[get-pb-dev] PocketBase v$PB_VERSION is ready at $PB_BIN"
}

# --- if binary exists, check version ---
if [[ -x "$PB_BIN" ]]; then
  BIN_VERSION="$(get_bin_version || true)"
  if [[ -n "$BIN_VERSION" && "$BIN_VERSION" == "$PB_VERSION" ]]; then
    echo "PocketBase v$BIN_VERSION is already installed at $PB_BIN"
    exit 0
  fi

  echo "==============================================================="
  echo "[get-pb-dev] PocketBase version mismatch!"
  echo "Expected: $PB_VERSION (from config.env)"
  echo "Found:    ${BIN_VERSION:-<unknown>}"
  echo "---------------------------------------------------------------"
  echo "Replace existing binary with v$PB_VERSION? [y/N]"
  read -r REPLACE
  case "${REPLACE:-}" in
    y|Y)
      rm -f "$PB_BIN"
      download_pb
      ;;
    *)
      echo "[get-pb-dev] Aborted. Binary left unchanged at $PB_BIN"
      exit 1
      ;;
  esac
else
  # No binary present — just download
  download_pb
fi
