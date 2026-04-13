#!/usr/bin/env bash
set -euo pipefail

# set-mode.sh <mode>
# Sets the session mode in the registry.
# Valid modes: autonomous (default), human-only
# Exit codes: 0=ok, 2=invalid mode, 10=corrupt registry, 11=lock failure

TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"
# shellcheck source=_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

MODE="${1:-}"
if [ -z "$MODE" ]; then
    echo "Usage: set-mode.sh <autonomous|human-only>" >&2
    exit 2
fi

case "$MODE" in
    autonomous|human-only) ;;
    *) echo "Error: invalid mode '$MODE'. Use 'autonomous' or 'human-only'" >&2; exit 2 ;;
esac

REGISTRY_FILE="${TEAM_QUEUE_DIR}/registry.json"
LOCK_FILE="${TEAM_QUEUE_DIR}/registry.lock"

if [ ! -f "$REGISTRY_FILE" ]; then
    echo "Error: registry not initialized" >&2
    exit 10
fi

# Find this session's name by PID
MY_PID="$SESSION_PID"

# Get process start time (macOS)
get_start_time() {
    local pid="$1"
    local lstart
    lstart=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//')
    [ -z "$lstart" ] && echo "0" && return
    date -j -f "%a %b %e %T %Y" "$lstart" "+%s" 2>/dev/null \
        || date -j -f "%a %b %d %T %Y" "$lstart" "+%s" 2>/dev/null \
        || echo "0"
}

MY_START=$(get_start_time "$MY_PID")

# Also allow TEAM_SESSION_BIT to identify the session
if [ -n "${TEAM_SESSION_BIT:-}" ]; then
    SESSION_NAME=$(jq -r --argjson bit "$TEAM_SESSION_BIT" \
        '[.sessions | to_entries[] | select(.value.bit == $bit)] | first | .key // empty' \
        "$REGISTRY_FILE" 2>/dev/null)
else
    SESSION_NAME=$(jq -r --argjson pid "$MY_PID" --argjson st "$MY_START" \
        '[.sessions | to_entries[] | select(.value.pid == $pid and .value.start_time == $st)] | first | .key // empty' \
        "$REGISTRY_FILE" 2>/dev/null)
fi

if [ -z "$SESSION_NAME" ] || [ "$SESSION_NAME" = "null" ]; then
    echo "Error: session not found in registry" >&2
    exit 2
fi

# Update mode under lock
export _SM_QUEUE="$TEAM_QUEUE_DIR"
export _SM_NAME="$SESSION_NAME"
export _SM_MODE="$MODE"

_INNER=$(mktemp "${TMPDIR:-/tmp}/sm_inner_$$.XXXXXX")
trap 'rm -f "$_INNER"' EXIT

cat > "$_INNER" << 'INNEREOF'
#!/usr/bin/env bash
set -euo pipefail
REG_FILE="${_SM_QUEUE}/registry.json"
REGISTRY=$(jq '.' "$REG_FILE" 2>/dev/null) || { echo "Error: corrupt registry" >&2; exit 10; }

REGISTRY=$(echo "$REGISTRY" | jq \
    --arg n "$_SM_NAME" \
    --arg m "$_SM_MODE" \
    '.sessions[$n].mode = $m')

TMP_REG=$(mktemp "${_SM_QUEUE}/registry.json.XXXXXX")
echo "$REGISTRY" | jq '.' > "$TMP_REG"
mv "$TMP_REG" "$REG_FILE"
INNEREOF

chmod +x "$_INNER"
lockf -k -t 5 "$LOCK_FILE" bash "$_INNER"

echo "Session '${SESSION_NAME}' mode set to '${MODE}'"
exit 0
