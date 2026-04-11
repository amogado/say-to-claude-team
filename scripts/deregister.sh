#!/usr/bin/env bash
set -euo pipefail

# deregister.sh
# Removes the current session from the registry and frees its bit.
# Exit codes: 0=ok, 6=session not found, 10=corrupt/missing registry, 11=lock failure

TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"
# shellcheck source=_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

REGISTRY_FILE="${TEAM_QUEUE_DIR}/registry.json"
LOCK_FILE="${TEAM_QUEUE_DIR}/registry.lock"
MY_PID="$SESSION_PID"

if [ -n "${TEAM_SESSION_BIT:-}" ]; then
    MY_BIT="$TEAM_SESSION_BIT"
else
    BIT_FILE="${TEAM_QUEUE_DIR}/.sessions/${SESSION_PID}.bit"
    if [ ! -f "$BIT_FILE" ]; then
        echo "Error: not registered (no bit file for PID $$ and TEAM_SESSION_BIT not set)" >&2
        exit 10
    fi
    MY_BIT=$(cat "$BIT_FILE")
fi

# Temp files for result passing
_RC=$(mktemp "${TMPDIR:-/tmp}/dereg_rc_$$.XXXXXX")
echo "11" > "$_RC"
_INNER=$(mktemp "${TMPDIR:-/tmp}/dereg_inner_$$.XXXXXX")
trap 'rm -f "$_RC" "$_INNER"' EXIT

# Pass variables via environment to avoid shell injection through heredoc expansion
export _DEREG_QUEUE="$TEAM_QUEUE_DIR"
export _DEREG_BIT="$MY_BIT"
export _DEREG_PID="$MY_PID"
export _DEREG_RC="$_RC"

# Quoted heredoc ('INNEREOF') prevents variable expansion — security fix
cat > "$_INNER" << 'INNEREOF'
#!/usr/bin/env bash
set -euo pipefail
QUEUE="$_DEREG_QUEUE"
MY_BIT="$_DEREG_BIT"
MY_PID="$_DEREG_PID"
RC_FILE="$_DEREG_RC"
REG_FILE="${QUEUE}/registry.json"

fail() { echo "$1" >&2; echo "$2" > "$RC_FILE"; exit "$2"; }

[ -f "$REG_FILE" ] || fail "Error: registry.json not found" 10
if ! REGISTRY=$(jq '.' "$REG_FILE" 2>/dev/null); then
    fail "Error: registry.json is corrupt" 10
fi

# Find session by bit (bit is unique per INV-R1)
FOUND=$(echo "$REGISTRY" | jq -r \
    --argjson bit "$MY_BIT" \
    '[.sessions | to_entries[] | select(.value.bit == $bit)] | .[0].key // empty')

if [ -z "$FOUND" ]; then
    fail "Error: session not found for bit=$MY_BIT" 6
fi

REGISTRY=$(echo "$REGISTRY" | jq \
    --arg n "$FOUND" --argjson bit "$MY_BIT" \
    'del(.sessions[$n]) | .recycled_bits += [$bit]')

TMP_REG=$(mktemp "${QUEUE}/registry.json.XXXXXX")
echo "$REGISTRY" | jq '.' > "$TMP_REG"
mv "$TMP_REG" "$REG_FILE"

echo "0" > "$RC_FILE"
INNEREOF

chmod +x "$_INNER"

lockf -k -t 5 "$LOCK_FILE" bash "$_INNER" || true

LOCK_RC=$(cat "$_RC")
case "$LOCK_RC" in
    0)  ;;
    6)  exit 6 ;;
    10) exit 10 ;;
    *)  echo "Error: failed to acquire registry lock" >&2; exit 11 ;;
esac

# Remove per-session local state files
rm -f "${TEAM_QUEUE_DIR}/.sessions/${MY_PID}.bit"
rm -f "${TEAM_QUEUE_DIR}/.sessions/${MY_PID}.start_time"

echo "Session deregistered (bit ${MY_BIT} recycled)" >&2
exit 0
