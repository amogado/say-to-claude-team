#!/usr/bin/env bash
set -euo pipefail

# heartbeat.sh
# Updates the current session's last_heartbeat timestamp in the registry.
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
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

touch "$LOCK_FILE"

_RC=$(mktemp "${TMPDIR:-/tmp}/hb_rc_$$.XXXXXX")
echo "11" > "$_RC"
_INNER=$(mktemp "${TMPDIR:-/tmp}/hb_inner_$$.XXXXXX")
trap 'rm -f "$_RC" "$_INNER"' EXIT

# Pass variables via environment to avoid shell injection through heredoc expansion
export _HB_QUEUE="$TEAM_QUEUE_DIR"
export _HB_BIT="$MY_BIT"
export _HB_PID="$MY_PID"
export _HB_NOW_ISO="$NOW_ISO"
export _HB_RC="$_RC"

# Quoted heredoc ('INNEREOF') prevents variable expansion — security fix
cat > "$_INNER" << 'INNEREOF'
#!/usr/bin/env bash
set -euo pipefail
QUEUE="$_HB_QUEUE"
MY_BIT="$_HB_BIT"
MY_PID="$_HB_PID"
NOW_ISO="$_HB_NOW_ISO"
RC_FILE="$_HB_RC"
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
    --arg n "$FOUND" --arg ts "$NOW_ISO" \
    '.sessions[$n].last_heartbeat = $ts')

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

exit 0
