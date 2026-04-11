#!/usr/bin/env bash
set -euo pipefail

# rename.sh <new-name>
# Renames the current session in the registry without changing its bit or PID.
# Exit codes: 0=ok, 2=invalid name/name taken, 6=not registered, 10=corrupt registry, 11=lock failure

TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"
# shellcheck source=_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <new-name>" >&2
    exit 2
fi

NEW_NAME="$1"
if ! echo "$NEW_NAME" | grep -qE '^[a-zA-Z0-9_-]+$'; then
    echo "Error: name must match [a-zA-Z0-9_-]+" >&2
    exit 2
fi

REGISTRY_FILE="${TEAM_QUEUE_DIR}/registry.json"
LOCK_FILE="${TEAM_QUEUE_DIR}/registry.lock"

if [ ! -f "$REGISTRY_FILE" ]; then
    echo "Error: registry.json not found. Run setup first." >&2
    exit 10
fi

touch "$LOCK_FILE"

# Find current session's bit
if [ -n "${TEAM_SESSION_BIT:-}" ]; then
    MY_BIT="$TEAM_SESSION_BIT"
else
    BIT_FILE="${TEAM_QUEUE_DIR}/.sessions/${SESSION_PID}.bit"
    if [ ! -f "$BIT_FILE" ]; then
        echo "Error: session not registered." >&2
        exit 6
    fi
    MY_BIT=$(cat "$BIT_FILE")
fi

# Run under lock
_RC=$(mktemp "${TMPDIR:-/tmp}/rename_rc_$$.XXXXXX")
echo "11" > "$_RC"
_INNER=$(mktemp "${TMPDIR:-/tmp}/rename_inner_$$.XXXXXX")
trap 'rm -f "$_RC" "$_INNER"' EXIT

export _REN_QUEUE="$TEAM_QUEUE_DIR"
export _REN_NEW_NAME="$NEW_NAME"
export _REN_BIT="$MY_BIT"
export _REN_RC="$_RC"

cat > "$_INNER" << 'INNEREOF'
#!/usr/bin/env bash
set -euo pipefail

QUEUE="$_REN_QUEUE"
NEW_NAME="$_REN_NEW_NAME"
MY_BIT="$_REN_BIT"

REGISTRY=$(cat "$QUEUE/registry.json") || { echo "10" > "$_REN_RC"; exit 0; }

# Find current name by bit
OLD_NAME=$(echo "$REGISTRY" | jq -r --argjson b "$MY_BIT" \
    '[.sessions | to_entries[] | select(.value.bit == $b) | .key] | first // ""')

if [ -z "$OLD_NAME" ]; then
    echo "Error: no session found with bit $MY_BIT" >&2
    echo "6" > "$_REN_RC"
    exit 0
fi

if [ "$OLD_NAME" = "$NEW_NAME" ]; then
    echo "Already named '$NEW_NAME'" >&2
    echo "0" > "$_REN_RC"
    exit 0
fi

# Check new name is not taken by another session
EXISTING=$(echo "$REGISTRY" | jq -r --arg n "$NEW_NAME" '.sessions[$n] // empty')
if [ -n "$EXISTING" ]; then
    echo "Error: name '$NEW_NAME' already taken" >&2
    echo "2" > "$_REN_RC"
    exit 0
fi

# Rename: copy session data to new key, delete old key
REGISTRY=$(echo "$REGISTRY" | jq --arg old "$OLD_NAME" --arg new "$NEW_NAME" \
    '.sessions[$new] = .sessions[$old] | del(.sessions[$old])')

TMP_REG=$(mktemp "$QUEUE/registry.json.XXXXXX")
echo "$REGISTRY" | jq '.' > "$TMP_REG"
mv "$TMP_REG" "$QUEUE/registry.json"

echo "Renamed '$OLD_NAME' → '$NEW_NAME' (bit $MY_BIT)" >&2
echo "0" > "$_REN_RC"
INNEREOF

chmod +x "$_INNER"
lockf -k -t 5 "$LOCK_FILE" bash "$_INNER"

RC=$(cat "$_RC")
exit "$RC"
