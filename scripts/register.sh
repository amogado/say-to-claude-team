#!/usr/bin/env bash
set -euo pipefail

# register.sh [name]
# Registers a new session. Outputs the assigned bit-position on stdout.
# Exit codes: 0=ok, 2=name taken, 10=corrupt registry, 11=lock failure

TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"
# shellcheck source=_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
# Validate TEAM_QUEUE_DIR: must be an absolute path with no shell metacharacters
case "$TEAM_QUEUE_DIR" in
    /*) ;; # absolute path — ok
    *) echo "Error: TEAM_QUEUE_DIR must be an absolute path" >&2; exit 2 ;;
esac
if [[ "$TEAM_QUEUE_DIR" =~ [\;\|\&\$\`\(\)\{\}\\] ]]; then
    echo "Error: TEAM_QUEUE_DIR contains disallowed characters" >&2; exit 2
fi

NAME="${1:-agent-$$}"
if ! echo "$NAME" | grep -qE '^[a-zA-Z0-9_-]+$'; then
    echo "Error: name must match [a-zA-Z0-9_-]+" >&2
    exit 2
fi

# Ensure directories and lock file exist
mkdir -p "${TEAM_QUEUE_DIR}/.sessions"
mkdir -p "${TEAM_QUEUE_DIR}/messages"
touch "${TEAM_QUEUE_DIR}/registry.lock"

# GC before registering — clean up dead sessions first (skip if TEAM_SKIP_GC is set)
if [ -z "${TEAM_SKIP_GC:-}" ]; then
    TEAM_SESSION_BIT="${TEAM_SESSION_BIT:-0}" bash "$(dirname "${BASH_SOURCE[0]}")/gc.sh" >/dev/null 2>&1 || true
    sleep 1
fi

# Get process start time as epoch seconds (macOS)
get_start_time() {
    local pid="$1"
    local lstart
    lstart=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//')
    [ -z "$lstart" ] && echo "0" && return
    date -j -f "%a %b %e %T %Y" "$lstart" "+%s" 2>/dev/null \
        || date -j -f "%a %b %d %T %Y" "$lstart" "+%s" 2>/dev/null \
        || echo "0"
}

NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MY_PID="$SESSION_PID"  # Claude's PID via _common.sh, not $$
START_TIME=$(get_start_time "$MY_PID")
REGISTRY_FILE="${TEAM_QUEUE_DIR}/registry.json"
LOCK_FILE="${TEAM_QUEUE_DIR}/registry.lock"

# Temp files: result bit and exit code from locked section
_OUT=$(mktemp "${TMPDIR:-/tmp}/reg_out_$$.XXXXXX")
_RC=$(mktemp "${TMPDIR:-/tmp}/reg_rc_$$.XXXXXX")
echo "11" > "$_RC"  # default: lock failure
trap 'rm -f "$_OUT" "$_RC"' EXIT

# Inner script that runs under lockf
_INNER=$(mktemp "${TMPDIR:-/tmp}/reg_inner_$$.XXXXXX")
trap 'rm -f "$_OUT" "$_RC" "$_INNER"' EXIT

# Pass variables via environment to avoid shell injection through heredoc expansion
export _REG_QUEUE="$TEAM_QUEUE_DIR"
export _REG_NAME="$NAME"
export _REG_PID="$MY_PID"
export _REG_START_TIME="$START_TIME"
export _REG_NOW_ISO="$NOW_ISO"
export _REG_OUT="$_OUT"
export _REG_RC="$_RC"

# Quoted heredoc ('INNEREOF') prevents variable expansion — security fix
cat > "$_INNER" << 'INNEREOF'
#!/usr/bin/env bash
set -euo pipefail
QUEUE="$_REG_QUEUE"
NAME="$_REG_NAME"
MY_PID="$_REG_PID"
START_TIME="$_REG_START_TIME"
NOW_ISO="$_REG_NOW_ISO"
OUT="$_REG_OUT"
RC_FILE="$_REG_RC"
REG_FILE="${QUEUE}/registry.json"

get_start_time() {
    local pid="$1"
    local lstart
    lstart=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//')
    [ -z "$lstart" ] && echo "0" && return
    date -j -f "%a %b %e %T %Y" "$lstart" "+%s" 2>/dev/null \
        || date -j -f "%a %b %d %T %Y" "$lstart" "+%s" 2>/dev/null \
        || echo "0"
}

fail() { echo "$1" >&2; echo "$2" > "$RC_FILE"; exit "$2"; }

if [ -f "$REG_FILE" ]; then
    if ! REGISTRY=$(jq '.' "$REG_FILE" 2>/dev/null); then
        fail "Error: registry.json is corrupt" 10
    fi
else
    REGISTRY='{"version":1,"sessions":{},"next_bit":0,"recycled_bits":[]}'
fi

# Check if this Claude PID is already registered under any name
EXISTING_BY_PID=$(echo "$REGISTRY" | jq -r --argjson pid "$MY_PID" \
    '[.sessions | to_entries[] | select(.value.pid == $pid)] | first // empty')
if [ -n "$EXISTING_BY_PID" ] && [ "$EXISTING_BY_PID" != "null" ]; then
    EXISTING_NAME=$(echo "$EXISTING_BY_PID" | jq -r '.key')
    EXISTING_BIT_PID=$(echo "$EXISTING_BY_PID" | jq -r '.value.bit')
    EXISTING_START_PID=$(echo "$EXISTING_BY_PID" | jq -r '.value.start_time')
    # Verify it's really the same process (not PID recycling)
    ACTUAL_START=$(get_start_time "$MY_PID")
    if [ "$ACTUAL_START" = "$EXISTING_START_PID" ] && [ "$ACTUAL_START" != "0" ]; then
        # Same PID, same start time → already registered
        echo "Already registered as '$EXISTING_NAME' (bit $EXISTING_BIT_PID)" >&2
        echo "$EXISTING_BIT_PID" > "$OUT"
        echo "0" > "$RC_FILE"
        exit 0
    fi
fi

EXISTING_JSON=$(echo "$REGISTRY" | jq -r --arg n "$NAME" '.sessions[$n] // empty')
if [ -n "$EXISTING_JSON" ]; then
    EXISTING_PID=$(echo "$EXISTING_JSON" | jq -r '.pid')
    EXISTING_START=$(echo "$EXISTING_JSON" | jq -r '.start_time')
    EXISTING_BIT=$(echo "$EXISTING_JSON" | jq -r '.bit')
    ALIVE=false
    if kill -0 "$EXISTING_PID" 2>/dev/null; then
        ACTUAL_START=$(get_start_time "$EXISTING_PID")
        if [ "$ACTUAL_START" = "$EXISTING_START" ] && [ "$ACTUAL_START" != "0" ]; then
            ALIVE=true
        fi
    fi
    if $ALIVE; then
        fail "Error: name '$NAME' already taken by live session PID $EXISTING_PID" 2
    fi
    echo "Reaping stale session '$NAME' (PID $EXISTING_PID, bit $EXISTING_BIT)" >&2
    REGISTRY=$(echo "$REGISTRY" | jq \
        --argjson bit "$EXISTING_BIT" --arg n "$NAME" \
        'del(.sessions[$n]) | .recycled_bits += [$bit]')
fi

if [ "$(echo "$REGISTRY" | jq '.recycled_bits | length')" -gt 0 ]; then
    BIT=$(echo "$REGISTRY" | jq -r '.recycled_bits[0]')
    REGISTRY=$(echo "$REGISTRY" | jq '.recycled_bits = .recycled_bits[1:]')
    if [ -d "${QUEUE}/messages" ]; then
        for msg_dir in "${QUEUE}/messages"/*/; do
            [ -d "$msg_dir" ] || continue
            ack_file="${msg_dir}ack/${BIT}"
            if [ -f "$ack_file" ]; then
                echo "Draining stale ack: $ack_file" >&2
                rm -f "$ack_file"
            fi
        done
    fi
else
    BIT=$(echo "$REGISTRY" | jq -r '.next_bit')
    REGISTRY=$(echo "$REGISTRY" | jq '.next_bit += 1')
fi

REGISTRY=$(echo "$REGISTRY" | jq \
    --arg n "$NAME" \
    --argjson bit "$BIT" \
    --argjson pid "$MY_PID" \
    --argjson st "$START_TIME" \
    --arg ra "$NOW_ISO" \
    --arg lh "$NOW_ISO" \
    '.sessions[$n] = {"bit":$bit,"pid":$pid,"start_time":$st,"registered_at":$ra,"last_heartbeat":$lh}')

TMP_REG=$(mktemp "${QUEUE}/registry.json.XXXXXX")
echo "$REGISTRY" | jq '.' > "$TMP_REG"
mv "$TMP_REG" "$REG_FILE"

echo "$BIT" > "$OUT"
echo "0" > "$RC_FILE"
INNEREOF

chmod +x "$_INNER"

# Run under advisory lock (5-second timeout)
lockf -k -t 5 "$LOCK_FILE" bash "$_INNER" || true

# Read results
LOCK_RC=$(cat "$_RC")
case "$LOCK_RC" in
    0)  ;;
    2)  exit 2 ;;
    10) exit 10 ;;
    *)  echo "Error: failed to acquire registry lock" >&2; exit 11 ;;
esac

BIT=$(cat "$_OUT")
RC=$(cat "$_RC")

if [ -z "$BIT" ]; then
    echo "Error: bit assignment failed" >&2
    exit 10
fi

# If already registered (RC=0 from PID check), just output the bit
if [ "$RC" = "0" ] && [ -f "${TEAM_QUEUE_DIR}/.sessions/${SESSION_PID}.bit" ]; then
    echo "$BIT"
    exit 0
fi

# Write per-session local state files
# Use resolved Claude PID so all scripts spawned by the same session share the same files
echo "$BIT" > "${TEAM_QUEUE_DIR}/.sessions/${SESSION_PID}.bit"
echo "$START_TIME" > "${TEAM_QUEUE_DIR}/.sessions/${SESSION_PID}.start_time"
touch "${TEAM_QUEUE_DIR}/.sessions/${SESSION_PID}.heartbeat"

echo "Registered as '${NAME}' (bit ${BIT})" >&2
echo "$BIT"
exit 0
