#!/usr/bin/env bash
set -euo pipefail

# pb-restore.sh
# - Prompts for admin creds and PB URL
# - Verifies backup object exists
# - Triggers restore to that snapshot (server will restart)
# Dependencies: curl, jq
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 70; }; }
need curl; need jq

echo "PocketBase restore (prod) — will only trigger restore, no migrations."

# --- Collect inputs interactively ---
read -r -p "PB_PUBLIC_URL (e.g. https://pb.yourdomain.com): " PB_PUBLIC_URL
PB_PUBLIC_URL="${PB_PUBLIC_URL%%/}"

read -r -p "PB_ADMIN_EMAIL: " PB_ADMIN_EMAIL
read -r -s -p "PB_ADMIN_PASSWORD: " PB_ADMIN_PASSWORD
echo

# Optional: if you protect restore with a header in prod (e.g. X-Restore-Key)
read -r -p "Restore secret header (optional, press Enter to skip): " PB_RESTORE_SECRET

echo
echo "Authenticating…"

# --- Auth helper (try both admins and superusers endpoints once) ---
auth_token() {
  local email="$1" pw="$2" base="$3"
  local body token

  body="$(jq -n --arg id "$email" --arg pw "$pw" '{identity:$id, password:$pw}')"

  # Try legacy admins endpoint
  token="$(curl -sS -X POST "$base/api/admins/auth-with-password" \
           -H "Content-Type: application/json" \
           --data-binary "$body" | jq -r '.token // empty' || true)"
  if [ -n "$token" ]; then echo "$token"; return 0; fi

  # Try newer superusers collection endpoint
  token="$(curl -sS -X POST "$base/api/collections/_superusers/auth-with-password" \
           -H "Content-Type: application/json" \
           --data-binary "$body" | jq -r '.token // empty' || true)"
  if [ -n "$token" ]; then echo "$token"; return 0; fi

  # Try shorthand superusers endpoint (some builds)
  token="$(curl -sS -X POST "$base/api/superusers/auth-with-password" \
           -H "Content-Type: application/json" \
           --data-binary "$body" | jq -r '.token // empty' || true)"
  if [ -n "$token" ]; then echo "$token"; return 0; fi

  echo ""
  return 1
}

TOKEN="$(auth_token "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" "$PB_PUBLIC_URL")" || true
if [ -z "$TOKEN" ]; then
  echo "ERROR: Authentication failed — check URL/credentials."
  exit 1
fi
echo "✓ Authenticated."

# --- Fetch backups list (best-effort) ---
echo "Fetching backup list…"
BACKUPS_JSON="$(curl -sS -H "Authorization: Bearer $TOKEN" "$PB_PUBLIC_URL/api/backups" || true)"

# Display a brief list to help user choose (if list call worked)
if [ -n "$BACKUPS_JSON" ] && [ "$BACKUPS_JSON" != "null" ]; then
  echo "Available backups (top 10):"
  echo "$BACKUPS_JSON" \
    | jq -r '.[0:10] | .[] | (.key // .name // .file // .filename // .File // .Name // .Key // .id // .Id // .ID)' \
    | sed '/^null$/d' || true
  echo
fi

read -r -p "PB_RESTORE_OBJECT (e.g. @auto_pb_backup_pocket_base_YYYYMMDDHHMMSS.zip): " PB_RESTORE_OBJECT

# --- Validate backup existence ---
exists_in_list=false
if [ -n "$BACKUPS_JSON" ] && [ "$BACKUPS_JSON" != "null" ]; then
  # Try to find a match in common fields
  MATCH="$(echo "$BACKUPS_JSON" | jq --arg k "$PB_RESTORE_OBJECT" \
    '[ .[] | {k:(.key // .name // .file // .filename // .File // .Name // .Key // .id // .Id // .ID)} | select(.k==$k) ] | length')"
  if [ "${MATCH:-0}" -gt 0 ]; then
    exists_in_list=true
  fi
fi

if [ "$exists_in_list" = false ]; then
  echo "Backup not found in list; attempting a header-only fetch to verify…"
  # Get a short-lived files token
  FILE_TOKEN="$(curl -sS -X POST "$PB_PUBLIC_URL/api/files/token" -H "Authorization: Bearer $TOKEN" | jq -r '.token // empty' || true)"
  if [ -z "$FILE_TOKEN" ]; then
    echo "ERROR: Could not obtain files token to verify backup existence."
    exit 1
  fi
  # URL-encode the key safely using jq
  ENC_KEY="$(printf '%s' "$PB_RESTORE_OBJECT" | jq -sRr @uri)"
  # HEAD request to download URL
  HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' -I "$PB_PUBLIC_URL/api/backups/$ENC_KEY?token=$FILE_TOKEN" || true)"
  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 400 ]; then
    echo "ERROR: Backup object not found (HTTP $HTTP_CODE)."
    exit 1
  fi
fi

echo
echo "About to RESTORE production to: $PB_RESTORE_OBJECT"
read -r -p "Type 'restore' to proceed: " CONFIRM
[ "$CONFIRM" = "restore" ] || { echo "Aborted."; exit 0; }

# --- Trigger restore ---
ENC_KEY="$(printf '%s' "$PB_RESTORE_OBJECT" | jq -sRr @uri)"
RESTORE_URL="$PB_PUBLIC_URL/api/backups/$ENC_KEY/restore"
HDRS=( -H "Authorization: Bearer $TOKEN" )
[ -n "${PB_RESTORE_SECRET:-}" ] && HDRS+=( -H "X-Restore-Key: $PB_RESTORE_SECRET" )

echo "Sending restore request…"
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$RESTORE_URL" "${HDRS[@]}" || true)"

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
  echo "✓ Restore requested successfully (HTTP $HTTP_CODE). PocketBase will restart."
  echo "Tip: After a minute, check health:  curl -fsS $PB_PUBLIC_URL/api/health | jq ."
else
  echo "ERROR: Restore request failed (HTTP $HTTP_CODE)."
  echo " - Ensure the backup key is correct and credentials/restore hook allow it."
  exit 1
fi
