#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PocketBase Dev Runner
# - Single admin via PB_ADMIN_EMAIL / PB_ADMIN_PASSWORD
# - Apply PB_PUBLIC_URL only
# - Version check against repo-root config.env: PB_VERSION
# - Works from any path inside the repo
# ============================================================

# --- find the repo root no matter where this script is called from ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  : # REPO_ROOT set by git
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
fi

# --- load env from repo root if present (supports override via PB_ENV_FILE) ---
# If PB_ENV_FILE is set (relative to repo root), it takes precedence.
if [[ -n "${PB_ENV_FILE:-}" && -f "$REPO_ROOT/$PB_ENV_FILE" ]]; then
  echo "[env] loading $PB_ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$REPO_ROOT/$PB_ENV_FILE"
  set +a
else
  for ENV_FILE in "$REPO_ROOT/.env" "$REPO_ROOT/.env.development" "$REPO_ROOT/.env.local"; do
    if [[ -f "$ENV_FILE" ]]; then
      echo "[env] loading $(basename "$ENV_FILE")"
      set -a
      # shellcheck disable=SC1090
      source "$ENV_FILE"
      set +a
    fi
  done
fi

# --- locations (absolute) ---
PB_DIR="$REPO_ROOT/dev-tools/.pocketbase-dev"
PB_BIN="$PB_DIR/pocketbase"
PB_DATA="$PB_DIR/pb_data"         # persistent local dev DB lives here
PB_MIG="$REPO_ROOT/pb_migrations"
PB_HOOKS="$REPO_ROOT/pb_hooks"
CONFIG_ENV="$REPO_ROOT/config.env"

# --- port + public url ---
PB_PORT="${PB_PORT:-8090}"
PB_PUBLIC_URL="${PB_PUBLIC_URL:-http://127.0.0.1:${PB_PORT}}"
PB_PUBLIC_URL="${PB_PUBLIC_URL%/}"

# --- optional: auto-download if missing (comment out if you don't want this) ---
if [[ ! -x "$PB_BIN" ]]; then
  echo "[run] PocketBase binary not found at $PB_BIN"
  if [[ -x "$REPO_ROOT/scripts/dev/get-pocketbase.sh" ]]; then
    echo "[run] Attempting auto-download..."
    bash "$REPO_ROOT/scripts/dev/get-pocketbase.sh"
  fi
fi

# --- sanity checks for tools ---
command -v curl >/dev/null 2>&1 || { echo "Error: curl is required"; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "Error: jq is required"; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { echo "Error: sqlite3 is required"; exit 1; }

# --- check PocketBase version from config.env (after optional auto-download) ---
if [[ -f "$CONFIG_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_ENV"
  if [[ -n "${PB_VERSION:-}" ]]; then
    if [[ ! -x "$PB_BIN" ]]; then
      echo "[version-check] ERROR: PocketBase binary not found at $PB_BIN"
      echo "                Expected version: $PB_VERSION"
      exit 1
    fi
    # pb --version prints like: "PocketBase version 0.22.14 (linux/amd64)"
    BIN_VERSION="$("$PB_BIN" --version 2>/dev/null | awk '{print $3}')"
    if [[ -z "$BIN_VERSION" ]]; then
      # older builds might print "version 0.21.16"
      BIN_VERSION_FALLBACK="$("$PB_BIN" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
      BIN_VERSION="${BIN_VERSION_FALLBACK:-unknown}"
    fi
    if [[ "$BIN_VERSION" != "$PB_VERSION" ]]; then
      echo "==============================================================="
      echo "[ERROR] PocketBase version mismatch!"
      echo "---------------------------------------------------------------"
      echo "Expected version: $PB_VERSION (from config.env)"
      echo "Found version:    $BIN_VERSION (from $PB_BIN)"
      echo "---------------------------------------------------------------"
      echo "To fix:"
      echo "  - Run get-pb-dev.sh again to download correct version."
      echo "    OR update PB_VERSION in config.env to match the binary."
      echo "==============================================================="
      exit 1
    fi
    echo "[version-check] PocketBase version OK: $PB_VERSION"
  else
    echo "[version-check] WARN: PB_VERSION not set in config.env, skipping version check."
  fi
else
  echo "[version-check] WARN: config.env not found at repo root, skipping version check."
fi

# --- env required for single-admin enforcement (after env files loaded) ---
: "${PB_ADMIN_EMAIL:?PB_ADMIN_EMAIL must be set}"
: "${PB_ADMIN_PASSWORD:?PB_ADMIN_PASSWORD must be set}"

# --- ensure dirs ---
mkdir -p "$PB_DATA"  # ensure data dir exists
[[ -d "$PB_MIG" ]] || echo "[warn] $PB_MIG not found (continuing)"
[[ -d "$PB_HOOKS" ]] || echo "[warn] $PB_HOOKS not found (continuing)"

# --- allow easy reset: PB_RESET=1 ./dev-tools/scripts/run-pb-dev.sh ---
if [[ "${PB_RESET:-0}" == "1" ]]; then
  echo "[run] PB_RESET=1 → wiping $PB_DATA"
  rm -rf "$PB_DATA"
  mkdir -p "$PB_DATA"
fi

# --- log important bits ---
echo "[run] bin:    $PB_BIN"
echo "[run] dir:    $PB_DATA   (persistent local dev DB)"
echo "[run] hooks:  $PB_HOOKS"
echo "[run] migs:   $PB_MIG"
echo "[run] http:   0.0.0.0:${PB_PORT}"
echo "[run] url:    ${PB_PUBLIC_URL}"
echo "[run] admin:  ${PB_ADMIN_EMAIL}"

[[ -x "$PB_BIN" ]] || { echo "Error: PocketBase not found or not executable at $PB_BIN"; exit 1; }

DB_PATH="$PB_DATA/data.db"
sql() { sqlite3 "$DB_PATH" "$1"; }
wal_ckpt() { sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true; }

# --- temp PB helpers (for init/bootstrap work) ---
BOOT_PORT="${BOOT_PORT:-8099}"
INIT_PORT="${INIT_PORT:-8097}"
PB_PID=""

start_temp() {
  "$PB_BIN" --dev --dir "$PB_DATA" --hooksDir "$PB_HOOKS" --migrationsDir "$PB_MIG" \
    serve --http 127.0.0.1:${BOOT_PORT} >/tmp/pb_bootstrap.log 2>&1 &
  PB_PID=$!
  for i in $(seq 1 120); do
    sleep 0.25
    if curl -fsS "http://127.0.0.1:${BOOT_PORT}/api/health" >/dev/null 2>&1; then
      return 0
    fi
  done
  echo "[bootstrap] PB failed to start"; tail -n 200 /tmp/pb_bootstrap.log || true
  return 1
}

stop_temp() {
  [[ -n "${PB_PID:-}" ]] && kill "$PB_PID" 2>/dev/null || true
  [[ -n "${PB_PID:-}" ]] && wait "$PB_PID" 2>/dev/null || true
  PB_PID=""
}

auth_token() {
  local email="$1" pw="$2" host="http://127.0.0.1:${BOOT_PORT}"
  local body resp code json token
  body="$(jq -n --arg id "$email" --arg pw "$pw" '{identity:$id, password:$pw}')"

  _try() {
    local path="$1"
    resp="$(curl -sS -w $'\n%{http_code}' -X POST "$host$path" \
      -H 'Content-Type: application/json' --data-binary "$body" || true)"
    code="${resp##*$'\n'}"
    json="${resp%$'\n'*}"
    if [[ "${code:-000}" -ge 200 && "${code:-000}" -lt 300 ]]; then
      token="$(printf '%s' "$json" | jq -r '.token // empty')"
      [[ -n "$token" ]] && { echo "$token"; return 0; }
    fi
    return 1
  }

  # PB <= v0.21
  _try "/api/admins/auth-with-password" && return 0
  # PB >= v0.22 (superusers collection)
  _try "/api/collections/_superusers/auth-with-password" && return 0
  # Some builds expose a shorthand
  _try "/api/superusers/auth-with-password" && return 0

  echo ""
  return 1
}

ensure_db_dir() {
  # Start once to create DB + run migrations if DB missing
  if [[ ! -f "$DB_PATH" ]]; then
    echo "[init] Starting PB once to initialize db/migrations…"
    "$PB_BIN" --dev --dir "$PB_DATA" --hooksDir "$PB_HOOKS" --migrationsDir "$PB_MIG" \
      serve --http 127.0.0.1:${INIT_PORT} >/tmp/pb_init.log 2>&1 &
    local init_pid=$!
    for i in $(seq 1 120); do
      sleep 0.25
      if curl -fsS "http://127.0.0.1:${INIT_PORT}/api/health" >/dev/null 2>&1; then
        sleep 0.5; break
      fi
      [[ "$i" -eq 120 ]] && echo "[init] PB failed to start" && cat /tmp/pb_init.log && exit 1
    done
    kill "$init_pid"; wait "$init_pid" 2>/dev/null || true
    echo "[init] Core/migrations initialized."
  fi
}

# --- bootstrap: ensure DB + enforce single admin + set PB_PUBLIC_URL ---
ensure_db_dir

echo "[admin] Enforcing single admin: $PB_ADMIN_EMAIL"
start_temp

TOKEN="$(auth_token "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" || true)"
ESC_ENV_EMAIL="$(printf "%s" "$PB_ADMIN_EMAIL" | sed "s/'/''/g")"

if [[ -n "${TOKEN:-}" ]]; then
  echo "[admin] Env admin login success."
  # Delete any other admins (support both PB <=0.21 and >=0.22 tables)
  sql "DELETE FROM _admins WHERE email <> '${ESC_ENV_EMAIL}';" >/dev/null 2>&1 || true
  sql "DELETE FROM _superusers WHERE email <> '${ESC_ENV_EMAIL}';" >/dev/null 2>&1 || true
  wal_ckpt
else
  echo "[admin] Env admin login failed. Recreating…"
  stop_temp || true

  # Remove non-env admins and any existing row for this email (both tables)
  sql "DELETE FROM _admins WHERE email <> '${ESC_ENV_EMAIL}';" >/dev/null 2>&1 || true
  sql "DELETE FROM _superusers WHERE email <> '${ESC_ENV_EMAIL}';" >/dev/null 2>&1 || true
  sql "DELETE FROM _admins WHERE email='${ESC_ENV_EMAIL}';" >/dev/null 2>&1 || true
  sql "DELETE FROM _superusers WHERE email='${ESC_ENV_EMAIL}';" >/dev/null 2>&1 || true
  wal_ckpt

  # Recreate env admin via CLI
  "$PB_BIN" --dir "$PB_DATA" --migrationsDir "$PB_MIG" \
    admin create "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" >/tmp/pb_admin_create.log 2>&1 || true
  cat /tmp/pb_admin_create.log || true

  # Bring PB back up and fetch a token
  start_temp
  TOKEN="$(auth_token "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" || true)"
  if [[ -z "${TOKEN:-}" ]]; then
    echo "[admin] ERROR: could not authenticate env admin after recreation."
    tail -n 200 /tmp/pb_bootstrap.log || true
    exit 1
  fi

  # Ensure invariant: single admin only
  sql "DELETE FROM _admins WHERE email <> '${ESC_ENV_EMAIL}';" >/dev/null 2>&1 || true
  sql "DELETE FROM _superusers WHERE email <> '${ESC_ENV_EMAIL}';" >/dev/null 2>&1 || true
  wal_ckpt
fi

# --- apply PB_PUBLIC_URL only (meta.appUrl) ---
DESIRED="$(jq -n --arg url "$PB_PUBLIC_URL" '{meta:{appName:"PocketBase", appUrl:$url}}')"
LIVE="$(curl -fsS -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:${BOOT_PORT}/api/settings")"

DESIRED_TRIM="$(printf '%s' "$DESIRED" | jq -S '{meta:{appUrl:.meta.appUrl}}')"
LIVE_TRIM="$(printf '%s' "$LIVE"     | jq -S '{meta:{appUrl:.meta.appUrl}}')"

if ! diff -q <(printf '%s\n' "$DESIRED_TRIM") <(printf '%s\n' "$LIVE_TRIM") >/dev/null 2>&1; then
  echo "[settings] Applying PB_PUBLIC_URL → ${PB_PUBLIC_URL}"
  PATCH_OUT="$(mktemp)"; PATCH_CODE=0
  printf '%s' "$DESIRED" | curl -sS -w "%{http_code}" -o "$PATCH_OUT" \
    -X PATCH "http://127.0.0.1:${BOOT_PORT}/api/settings" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    --data-binary @- > /tmp/pb_patch_code.txt || PATCH_CODE=$?
  HTTP_CODE="$(cat /tmp/pb_patch_code.txt || echo 000)"
  if [[ "$PATCH_CODE" -ne 0 || "$HTTP_CODE" -ge 400 ]]; then
    echo "[settings] PATCH failed (HTTP $HTTP_CODE). Response:"; cat "$PATCH_OUT"
    echo "--- bootstrap.log (tail) ---"; tail -n 200 /tmp/pb_bootstrap.log || true
    stop_temp
    exit 1
  fi
else
  echo "[settings] No settings changes needed."
fi

# --- stop temp and start the real dev server ---
stop_temp
echo "[bootstrap] Done. Starting dev server…"

exec "$PB_BIN" serve \
  --http "0.0.0.0:${PB_PORT}" \
  --dir "$PB_DATA" \
  --migrationsDir "$PB_MIG" \
  --hooksDir "$PB_HOOKS"
