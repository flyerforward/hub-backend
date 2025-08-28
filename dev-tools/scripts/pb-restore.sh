#!/usr/bin/env bash
set -euo pipefail

# pb-restore.sh
# - Auth to PB (supports self-signed via -k / custom CA via --cacert)
# - TEMP bump backups.cronMaxKeep by +1, create rollback backup (robust 204 handling)
# - Download chosen backup; extract ALL; locate any */pb_migrations dir
# - Git: overwrite repo ./pb_migrations, commit & push using existing git auth; if no changes, skip push and still restore
# - Trigger restore; on success try re-auth and delete rollback backup
#
# Deps: curl, jq, unzip, rsync, git, coreutils (comm)

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 70; }; }
need curl; need jq; need unzip; need rsync; need git; need comm

REPO_MIG_DIR="${REPO_MIG_DIR:-./pb_migrations}"

echo "PocketBase restore (prod): sync & push pb_migrations, then restore with rollback safety."

# --- Collect PB inputs ---
read -r -p "PB_PUBLIC_URL (e.g. https://pb.yourdomain.com): " PB_PUBLIC_URL
PB_PUBLIC_URL="${PB_PUBLIC_URL%%/}"

read -r -p "PB_ADMIN_EMAIL: " PB_ADMIN_EMAIL
read -r -s -p "PB_ADMIN_PASSWORD: " PB_ADMIN_PASSWORD
echo

# TLS options
if [[ -z "${PB_INSECURE:-}" && -z "${PB_CACERT:-}" && "${PB_PUBLIC_URL}" == https://* ]]; then
  read -r -p "Skip TLS verification for HTTPS (self-signed)? [y/N]: " SKIPTLS
  case "${SKIPTLS:-}" in y|Y) PB_INSECURE=1 ;; *) PB_INSECURE=0 ;; esac
fi

# Optional: break-glass restore header
read -r -p "Restore secret header (optional, press Enter to skip): " PB_RESTORE_SECRET

# Build curl opts
CURL_OPTS=(-sS)
if [[ "${PB_PUBLIC_URL}" == https://* ]]; then
  if [[ "${PB_INSECURE:-0}" == "1" ]]; then
    CURL_OPTS+=(-k); echo "NOTE: TLS verification disabled (-k)."
  elif [[ -n "${PB_CACERT:-}" ]]; then
    CURL_OPTS+=(--cacert "$PB_CACERT"); echo "Using custom CA bundle: $PB_CACERT"
  fi
fi
_curl(){ curl "${CURL_OPTS[@]}" "$@"; }

echo
echo "Authenticating…"

# --- Auth helper (admins -> superusers -> shorthand) ---
auth_token() {
  local email="$1" pw="$2" base="$3" body token
  body="$(jq -n --arg id "$email" --arg pw "$pw" '{identity:$id, password:$pw}')"
  token="$(_curl -X POST "$base/api/admins/auth-with-password" \
              -H "Content-Type: application/json" \
              --data-binary "$body" | jq -r '.token // empty' || true)"
  [[ -n "$token" ]] && { echo "$token"; return 0; }

  token="$(_curl -X POST "$base/api/collections/_superusers/auth-with-password" \
              -H "Content-Type: application/json" \
              --data-binary "$body" | jq -r '.token // empty' || true)"
  [[ -n "$token" ]] && { echo "$token"; return 0; }

  token="$(_curl -X POST "$base/api/superusers/auth-with-password" \
              -H "Content-Type: application/json" \
              --data-binary "$body" | jq -r '.token // empty' || true)"
  [[ -n "$token" ]] && { echo "$token"; return 0; }

  echo ""; return 1
}

TOKEN="$(auth_token "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" "$PB_PUBLIC_URL")" || true
if [[ -z "$TOKEN" ]]; then
  echo "ERROR: Authentication failed — check URL/credentials (or TLS settings)."
  exit 1
fi
echo "✓ Authenticated."

# --- List backups (best-effort) ---
echo "Fetching backup list…"
BACKUPS_JSON="$(_curl -H "Authorization: Bearer $TOKEN" "$PB_PUBLIC_URL/api/backups" || true)"
if [[ -n "$BACKUPS_JSON" && "$BACKUPS_JSON" != "null" ]]; then
  echo "Available backups (top 10):"
  echo "$BACKUPS_JSON" \
    | jq -r '.[0:10] | .[] | (.key // .name // .file // .filename // .File // .Name // .Key // .id // .Id // .ID)' \
    | sed '/^null$/d' || true
  echo
fi

read -r -p "PB_RESTORE_OBJECT (e.g. @auto_pb_backup_pocket_base_YYYYMMDDHHMMSS.zip): " PB_RESTORE_OBJECT

# --- Files token (for download URLs) ---
FILE_TOKEN="$(_curl -X POST "$PB_PUBLIC_URL/api/files/token" \
  -H "Authorization: Bearer $TOKEN" | jq -r '.token // empty' || true)"
if [[ -z "$FILE_TOKEN" ]]; then
  echo "ERROR: Could not obtain files token."
  exit 1
fi

# --- Validate backup existence (list or HEAD) ---
exists_in_list=false
if [[ -n "$BACKUPS_JSON" && "$BACKUPS_JSON" != "null" ]]; then
  MATCH="$(echo "$BACKUPS_JSON" | jq --arg k "$PB_RESTORE_OBJECT" \
    '[ .[] | {k:(.key // .name // .file // .filename // .File // .Name // .Key // .id // .Id // .ID)} | select(.k==$k) ] | length')"
  [[ "${MATCH:-0}" -gt 0 ]] && exists_in_list=true
fi
if [[ "$exists_in_list" = false ]]; then
  echo "Backup not found in list; HEAD-checking download URL…"
  ENC_CHECK="$(printf '%s' "$PB_RESTORE_OBJECT" | jq -sRr @uri)"
  HTTP_CODE="$(_curl -o /dev/null -w '%{http_code}' -I \
    "$PB_PUBLIC_URL/api/backups/$ENC_CHECK?token=$FILE_TOKEN" || true)"
  if [[ -z "$HTTP_CODE" || "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 400 ]]; then
    echo "ERROR: Backup object not found (HTTP ${HTTP_CODE:-000})."
    exit 1
  fi
fi

echo
echo "About to proceed with rollback safety + restore to: $PB_RESTORE_OBJECT"
read -r -p "Type 'restore' to continue: " CONFIRM
[[ "$CONFIRM" == "restore" ]] || { echo "Aborted."; exit 0; }

# ========== ROLLBACK & KEEP HANDLING (robust) ==========
echo "Reading current settings…"
SETTINGS_JSON="$(_curl -H "Authorization: Bearer $TOKEN" "$PB_PUBLIC_URL/api/settings")"
ORIG_KEEP="$(echo "$SETTINGS_JSON" | jq -r '.backups.cronMaxKeep // 0')"
NEW_KEEP="$(( ORIG_KEEP + 1 ))"

echo "Temporarily setting backups.cronMaxKeep: $ORIG_KEEP → $NEW_KEEP"
PATCH_KEEP="$(jq -n --argjson keep "$NEW_KEEP" '{backups:{cronMaxKeep:$keep}}')"
HTTP_CODE="$(_curl -o /dev/null -w '%{http_code}' -X PATCH "$PB_PUBLIC_URL/api/settings" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data-binary "$PATCH_KEEP" || true)"
if [[ -z "$HTTP_CODE" || "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 300 ]]; then
  echo "ERROR: Failed to bump cronMaxKeep (HTTP ${HTTP_CODE:-000})."
  exit 1
fi

# Take a snapshot of existing backup keys
list_keys() {
  jq -r '.[] | (.key // .name // .file // .filename // .File // .Name // .Key // .id // .Id // .ID // empty)' 2>/dev/null
}
BEFORE_JSON="$(_curl -H "Authorization: Bearer $TOKEN" "$PB_PUBLIC_URL/api/backups" || echo "[]")"
BEFORE_KEYS="$(echo "$BEFORE_JSON" | list_keys | sort -u || true)"

TS="$(date -u +%Y%m%d%H%M%S)"
REQ_NAME="rollback_${TS}.zip"
echo "Creating rollback backup: $REQ_NAME (server may return 204)…"
HTTP_CODE="$(_curl -o /dev/null -w '%{http_code}' -X POST "$PB_PUBLIC_URL/api/backups" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data-binary "$(jq -n --arg name "$REQ_NAME" '{name:$name}')" || true)"
if [[ -z "$HTTP_CODE" || "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 300 ]]; then
  echo "ERROR: Failed to create rollback backup (HTTP ${HTTP_CODE:-000})."
  PATCH_REVERT="$(jq -n --argjson keep "$ORIG_KEEP" '{backups:{cronMaxKeep:$keep}}')"
  _curl -o /dev/null -w '%{http_code}' -X PATCH "$PB_PUBLIC_URL/api/settings" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    --data-binary "$PATCH_REVERT" >/dev/null 2>&1 || true
  exit 1
fi

# Poll for a new backup key (up to ~60s)
echo "Waiting for rollback backup to appear…"
ROLLBACK_KEY=""
for i in $(seq 1 60); do
  sleep 1
  NOW_JSON="$(_curl -H "Authorization: Bearer $TOKEN" "$PB_PUBLIC_URL/api/backups" || echo "[]")"
  NOW_KEYS="$(echo "$NOW_JSON" | list_keys | sort -u || true)"
  NEW_KEY="$(comm -13 <(printf '%s\n' $BEFORE_KEYS) <(printf '%s\n' $NOW_KEYS) | head -n1 || true)"
  if [[ -n "$NEW_KEY" ]]; then
    ROLLBACK_KEY="$NEW_KEY"
    break
  fi
done

if [[ -z "$ROLLBACK_KEY" ]]; then
  echo "ERROR: Rollback backup did not show up in time."
  PATCH_REVERT="$(jq -n --argjson keep "$ORIG_KEEP" '{backups:{cronMaxKeep:$keep}}')"
  _curl -o /dev/null -w '%{http_code}' -X PATCH "$PB_PUBLIC_URL/api/settings" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    --data-binary "$PATCH_REVERT" >/dev/null 2>&1 || true
  exit 1
fi
echo "✓ Rollback backup key: $ROLLBACK_KEY"

# Restore maxKeep immediately now that rollback exists
PATCH_REVERT="$(jq -n --argjson keep "$ORIG_KEEP" '{backups:{cronMaxKeep:$keep}}')"
_curl -o /dev/null -w '%{http_code}' -X PATCH "$PB_PUBLIC_URL/api/settings" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data-binary "$PATCH_REVERT" >/dev/null 2>&1 || true
echo "cronMaxKeep restored to $ORIG_KEEP"

# ========== DOWNLOAD + FIND MIGRATIONS ==========
TMP="$(mktemp -d)"
ZIP="$TMP/backup.zip"
EX="$TMP/extract"; mkdir -p "$EX"
ENC_KEY="$(printf '%s' "$PB_RESTORE_OBJECT" | jq -sRr @uri)"

echo "Downloading selected backup ZIP…"
_curl -L -o "$ZIP" "$PB_PUBLIC_URL/api/backups/$ENC_KEY?token=$FILE_TOKEN"

echo "Extracting archive to temp…"
unzip -q "$ZIP" -d "$EX" || true
SRC_MIGS="$(find "$EX" -type d -name pb_migrations | head -n1 || true)"
if [[ -z "$SRC_MIGS" || ! -d "$SRC_MIGS" ]]; then
  echo "ERROR: No 'pb_migrations' directory found anywhere in the backup."
  echo "Cleaning up: deleting rollback '$ROLLBACK_KEY'…"
  _curl -X DELETE "$PB_PUBLIC_URL/api/backups/$(printf '%s' "$ROLLBACK_KEY" | jq -sRr @uri)" \
    -H "Authorization: Bearer $TOKEN" >/dev/null 2>&1 || true
  exit 1
fi

# ========== GIT: COPY, COMMIT, PUSH (native auth only) ==========
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "ERROR: Not inside a Git repository. Run this script from within your project repo."
  exit 1
fi

STASHED=0
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
  echo "Working tree has uncommitted changes."
  read -r -p "Stash them automatically? [Y/n]: " DO_STASH
  if [[ "${DO_STASH:-Y}" =~ ^(Y|y)?$ ]]; then
    git -C "$REPO_ROOT" stash push -u -m "pb-restore auto-stash $(date -u +%FT%TZ)"
    STASHED=1
    echo "✓ Stashed."
  else
    echo "Please commit/stash or revert your working tree changes and re-run."; exit 1
  fi
fi

DEFAULT_REMOTE="origin"
read -r -p "Git remote to push to [${DEFAULT_REMOTE}]: " REMOTE
REMOTE="${REMOTE:-$DEFAULT_REMOTE}"
if ! git -C "$REPO_ROOT" remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "ERROR: Remote '$REMOTE' not found."; exit 1
fi

START_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
START_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD)"

CURRENT_BRANCH="$START_BRANCH"
SLUG="$(printf '%s' "$PB_RESTORE_OBJECT" | sed -E 's/(\.zip)$//; s/[^A-Za-z0-9._-]+/-/g; s/^-+|-+$//g')"
DEF_BRANCH="restore/$(date +%Y%m%d)-${SLUG}"
read -r -p "Create and push a new branch '$DEF_BRANCH'? [Y/n] " MAKE_BRANCH
if [[ "${MAKE_BRANCH:-Y}" =~ ^(Y|y)?$ ]]; then
  TARGET_BRANCH="$DEF_BRANCH"
  git -C "$REPO_ROOT" checkout -B "$TARGET_BRANCH"
  MADE_NEW_BRANCH=1
else
  TARGET_BRANCH="$CURRENT_BRANCH"
  MADE_NEW_BRANCH=0
  echo "Using current branch: $TARGET_BRANCH"
fi

rollback_git() {
  echo "Rolling back repo changes…"
  git -C "$REPO_ROOT" reset --hard "$START_HEAD" || true
  if [[ "$MADE_NEW_BRANCH" -eq 1 ]]; then
    git -C "$REPO_ROOT" checkout "$START_BRANCH" || true
    git -C "$REPO_ROOT" branch -D "$TARGET_BRANCH" >/dev/null 2>&1 || true
  fi
  if [[ "$STASHED" -eq 1 ]]; then
    git -C "$REPO_ROOT" stash pop || true
  fi
}

DEST_MIGS="$REPO_ROOT/pb_migrations"
mkdir -p "$DEST_MIGS"
rsync -a --delete "$SRC_MIGS/." "$DEST_MIGS/"

# If nothing changed in pb_migrations, skip commit/push and proceed to restore
if git -C "$REPO_ROOT" diff --quiet --exit-code -- "pb_migrations"; then
  echo "No changes in pb_migrations; skipping commit/push."
  # If we created a temp branch for this but there are no changes, clean it up to avoid confusion
  if [[ "$MADE_NEW_BRANCH" -eq 1 ]]; then
    git -C "$REPO_ROOT" checkout "$START_BRANCH" || true
    git -C "$REPO_ROOT" branch -D "$TARGET_BRANCH" >/dev/null 2>&1 || true
    MADE_NEW_BRANCH=0
  fi
  # Restore any stash before continuing
  if [[ "$STASHED" -eq 1 ]]; then
    git -C "$REPO_ROOT" stash pop || true
    STASHED=0
  fi
else
  git -C "$REPO_ROOT" add "pb_migrations"
  git -C "$REPO_ROOT" commit -m "Restore schema to $PB_RESTORE_OBJECT (sync pb_migrations from backup)"

  echo "Pushing '$TARGET_BRANCH' to '$REMOTE' using existing git auth…"
  if ! git -C "$REPO_ROOT" push -u "$REMOTE" "$TARGET_BRANCH"; then
    echo "ERROR: git push failed (auth or permission issue)."
    rollback_git
    echo "Deleting rollback backup '$ROLLBACK_KEY'…"
    _curl -X DELETE "$PB_PUBLIC_URL/api/backups/$(printf '%s' "$ROLLBACK_KEY" | jq -sRr @uri)" \
      -H "Authorization: Bearer $TOKEN" >/dev/null 2>&1 || true
    exit 1
  fi
  echo "✓ Local pb_migrations now matches the chosen backup and is pushed."
fi

# ========== TRIGGER RESTORE ==========
RESTORE_URL="$PB_PUBLIC_URL/api/backups/$ENC_KEY/restore"
HDRS=( -H "Authorization: Bearer $TOKEN" )
[[ -n "${PB_RESTORE_SECRET:-}" ]] && HDRS+=( -H "X-Restore-Key: $PB_RESTORE_SECRET" )

echo "Sending restore request…"
HTTP_CODE="$(_curl -o /dev/null -w '%{http_code}' -X POST "$RESTORE_URL" "${HDRS[@]}" || true)"
if [[ -z "$HTTP_CODE" || "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 300 ]]; then
  echo "ERROR: Restore request failed (HTTP ${HTTP_CODE:-000})."
  echo "Rollback backup kept: $ROLLBACK_KEY"
  exit 1
fi
echo "✓ Restore requested successfully (HTTP $HTTP_CODE). PocketBase will restart."

# ========== POST-RESTORE CLEANUP ==========
echo "Waiting a few seconds for PB to come back…"
sleep 6
POST_TOKEN="$(auth_token "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" "$PB_PUBLIC_URL")" || true
if [[ -n "$POST_TOKEN" ]]; then
  echo "Re-auth succeeded post-restore. Deleting rollback backup…"
  _curl -X DELETE "$PB_PUBLIC_URL/api/backups/$(printf '%s' "$ROLLBACK_KEY" | jq -sRr @uri)" \
    -H "Authorization: Bearer $POST_TOKEN" >/dev/null 2>&1 || true
  echo "✓ Cleanup done."
else
  echo "NOTE: Could not re-auth after restore (admin creds may differ in snapshot)."
  echo "Rollback backup kept: $ROLLBACK_KEY"
  echo "After env-admin is re-enforced (e.g., redeploy), delete it with:"
  echo "  curl ${CURL_OPTS[*]} -H 'Authorization: Bearer <TOKEN>' -X DELETE \\"
  echo "       '$PB_PUBLIC_URL/api/backups/$(printf '%s' "$ROLLBACK_KEY" | jq -sRr @uri)'"
fi

echo
echo "All done ✅"
