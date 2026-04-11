#!/usr/bin/env bash
set -euo pipefail

# check-messages.sh — Ultra-fast unread message checker for Claude Code PreToolUse hook
# Called before every tool invocation. Must complete in < 100ms.
# Exit 0: no messages (hook continues silently)
# Exit 1: messages found (hook injects output into context)

TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"
SESSIONS_DIR="$TEAM_QUEUE_DIR/.sessions"
MESSAGES_DIR="$TEAM_QUEUE_DIR/messages"

# Resolve the Claude session PID by walking up the process tree
_resolve_pid() {
    if [ -n "${TEAM_SESSION_PID:-}" ]; then echo "$TEAM_SESSION_PID"; return; fi
    local pid=$$
    while [ "$pid" -gt 1 ]; do
        local parent; parent=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d " ")
        [ -z "$parent" ] && break
        local comm; comm=$(ps -p "$parent" -o comm= 2>/dev/null)
        if [ "$comm" = "claude" ]; then echo "$parent"; return; fi
        pid="$parent"
    done
    echo "$PPID"
}
SESSION_PID="$(_resolve_pid)"

# Fast-path: check if this session is registered
BIT_FILE="$SESSIONS_DIR/${SESSION_PID}.bit"
[[ -f "$BIT_FILE" ]] || exit 0

MY_BIT="$(< "$BIT_FILE")"

# Update heartbeat — non-blocking, best-effort
# Update heartbeat — non-blocking, best-effort
touch "$SESSIONS_DIR/${SESSION_PID}.heartbeat" 2>/dev/null || true

# Scan messages directory for unread messages targeting our bit
# Uses pure bash/awk — no jq dependency for speed
[[ -d "$MESSAGES_DIR" ]] || exit 0

declare -a MSG_IDS=()
declare -a MSG_SENDERS=()
declare -a MSG_AGES=()
declare -a MSG_TYPES=()
declare -a MSG_BODIES=()

NOW=$(date +%s)

for MSG_DIR in "$MESSAGES_DIR"/*/; do
    # Skip staging dirs and non-directories
    MSG_ID="${MSG_DIR%/}"
    MSG_ID="${MSG_ID##*/}"
    [[ "$MSG_ID" == .* ]] && continue
    [[ -d "$MSG_DIR" ]] || continue

    REQUIRED_FILE="$MSG_DIR/required"
    [[ -f "$REQUIRED_FILE" ]] || continue

    REQUIRED="$(< "$REQUIRED_FILE")"
    # Check if our bit is in the required mask: (required >> my_bit) & 1
    BIT_SET=$(( (REQUIRED >> MY_BIT) & 1 ))
    [[ "$BIT_SET" -eq 1 ]] || continue

    # Check if already acked
    [[ -f "$MSG_DIR/ack/$MY_BIT" ]] && continue

    # Read payload with awk — parse specific fields without jq
    PAYLOAD_FILE="$MSG_DIR/payload.json"
    [[ -f "$PAYLOAD_FILE" ]] || continue

    # Extract sender name, type, body, and timestamp using awk
    read -r SENDER MSG_TYPE TIMESTAMP BODY < <(awk '
        BEGIN { sender="?"; mtype="?"; ts=""; body=""; in_body=0 }
        /"sender"/ { in_sender=1 }
        in_sender && /"name"/ {
            match($0, /"name": *"([^"]+)"/, arr)
            sender = arr[1]
            in_sender=0
        }
        /"type"/ && !in_sender {
            match($0, /"type": *"([^"]+)"/, arr)
            mtype = arr[1]
        }
        /"timestamp"/ {
            match($0, /"timestamp": *"([^"]+)"/, arr)
            ts = arr[1]
        }
        /"body"/ {
            match($0, /"body": *"(.*)"/, arr)
            body = arr[1]
        }
        END { print sender, mtype, ts, body }
    ' "$PAYLOAD_FILE") || continue

    # Compute age from ISO8601 timestamp (strip timezone, parse with date)
    MSG_EPOCH=0
    if [[ -n "$TIMESTAMP" ]]; then
        # macOS date -j -f format
        CLEAN_TS="${TIMESTAMP%Z}"
        CLEAN_TS="${CLEAN_TS/T/ }"
        MSG_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S" "$CLEAN_TS" +%s 2>/dev/null || echo 0)
    fi

    AGE_SECS=$(( NOW - MSG_EPOCH ))
    if (( AGE_SECS < 10 )); then
        AGE_STR="just now"
    elif (( AGE_SECS < 60 )); then
        AGE_STR="${AGE_SECS}s ago"
    elif (( AGE_SECS < 3600 )); then
        AGE_STR="$(( AGE_SECS / 60 ))m ago"
    else
        AGE_STR="$(( AGE_SECS / 3600 ))h ago"
    fi

    MSG_IDS+=("$MSG_ID")
    MSG_SENDERS+=("$SENDER")
    MSG_AGES+=("$AGE_STR")
    MSG_TYPES+=("$MSG_TYPE")
    # Truncate body for display
    if [[ ${#BODY} -gt 80 ]]; then
        MSG_BODIES+=("${BODY:0:77}...")
    else
        MSG_BODIES+=("$BODY")
    fi
done

COUNT="${#MSG_IDS[@]}"
[[ "$COUNT" -eq 0 ]] && exit 0

# Format output
if [[ "$COUNT" -eq 1 ]]; then
    echo "[Team Queue] 1 unread message — run /say-to-claude-team check to read"
else
    echo "[Team Queue] $COUNT unread messages — run /say-to-claude-team check to read"
fi
echo ""

for (( i=0; i<COUNT; i++ )); do
    echo "[$((i+1))] From: ${MSG_SENDERS[$i]} (${MSG_AGES[$i]}) [${MSG_TYPES[$i]}]"
    echo "    ${MSG_BODIES[$i]}"
    if (( i < COUNT - 1 )); then
        echo ""
    fi
done

exit 1
