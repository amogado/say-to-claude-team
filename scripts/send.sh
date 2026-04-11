#!/usr/bin/env bash
set -euo pipefail

# send.sh <target> <type> <body>
# Posts a message to one or all sessions. Outputs msg-id on stdout.
# Exit codes: 0=ok, 1=no recipients, 3=send to self, 10=corrupt/missing, 12=staging failure

TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"
# shellcheck source=_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
TEAM_TTL_DEFAULT="${TEAM_TTL_DEFAULT:-3600}"
TEAM_MSG_PRIORITY="${TEAM_MSG_PRIORITY:-normal}"
TEAM_MSG_TTL="${TEAM_MSG_TTL:-$TEAM_TTL_DEFAULT}"
TEAM_MSG_REPLY_TO="${TEAM_MSG_REPLY_TO:-null}"

if [ $# -lt 3 ]; then
    echo "Usage: $0 <target> <type> <body>" >&2
    echo "  target: 'all' or a session name" >&2
    echo "  type:   text | command | query" >&2
    echo "  body:   message content (UTF-8)" >&2
    exit 2
fi

TARGET="$1"
MSG_TYPE="$2"
BODY="$3"

# Validate type
case "$MSG_TYPE" in
    text|command|query) ;;
    *) echo "Error: type must be one of: text, command, query" >&2; exit 2 ;;
esac

# Validate priority
case "$TEAM_MSG_PRIORITY" in
    normal|high) ;;
    *) echo "Error: TEAM_MSG_PRIORITY must be 'normal' or 'high'" >&2; exit 2 ;;
esac

# Read our bit (no lock needed — only we write this)
MY_PID="$SESSION_PID"
if [ -n "${TEAM_SESSION_BIT:-}" ]; then
    MY_BIT="$TEAM_SESSION_BIT"
    MY_START_TIME=$(cat "${TEAM_QUEUE_DIR}/.sessions/${SESSION_PID}.start_time" 2>/dev/null || echo "0")
else
    BIT_FILE="${TEAM_QUEUE_DIR}/.sessions/${SESSION_PID}.bit"
    START_FILE="${TEAM_QUEUE_DIR}/.sessions/${SESSION_PID}.start_time"
    if [ ! -f "$BIT_FILE" ]; then
        echo "Error: session not registered. Run 'bash scripts/register.sh <name>' first." >&2
        exit 10
    fi
    MY_BIT=$(cat "$BIT_FILE")
    MY_START_TIME=$(cat "$START_FILE" 2>/dev/null || echo "0")
fi

REGISTRY_FILE="${TEAM_QUEUE_DIR}/registry.json"
if [ ! -f "$REGISTRY_FILE" ]; then
    echo "Error: registry.json not found. Run 'bash scripts/setup.sh' first." >&2
    exit 10
fi
if ! REGISTRY=$(jq '.' "$REGISTRY_FILE" 2>/dev/null); then
    echo "Error: registry.json is corrupt" >&2
    exit 10
fi

# Compute required bitmask (no lock — snapshot read is sufficient)
if [ "$TARGET" = "all" ]; then
    # All active sessions except sender
    REQUIRED=$(echo "$REGISTRY" | jq \
        --argjson mybit "$MY_BIT" \
        '[.sessions | to_entries[] | select(.value.bit != $mybit) | .value.bit] |
         reduce .[] as $b (0; . + (1 * pow(2; $b))) | floor')
else
    # Directed message to a specific session
    TARGET_BIT=$(echo "$REGISTRY" | jq -r \
        --arg tgt "$TARGET" \
        '.sessions[$tgt].bit // empty')
    if [ -z "$TARGET_BIT" ]; then
        echo "Error: target session '$TARGET' not found" >&2
        exit 1
    fi
    if [ "$TARGET_BIT" = "$MY_BIT" ]; then
        echo "Error: cannot send message to self" >&2
        exit 3
    fi
    REQUIRED=$((1 << TARGET_BIT))
fi

if [ "$REQUIRED" -eq 0 ]; then
    echo "Error: no recipients (no other active sessions)" >&2
    exit 1
fi

# Look up our own session name from registry
MY_NAME=$(echo "$REGISTRY" | jq -r \
    --argjson bit "$MY_BIT" \
    '[.sessions | to_entries[] | select(.value.bit == $bit)] | .[0].key // "unknown"')

# Generate message ID
MSG_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Handle reply_to: validate UUID format if set, pass safely via jq --arg
if [ "$TEAM_MSG_REPLY_TO" = "null" ]; then
    REPLY_TO_JSON="null"
else
    # Validate reply_to is a valid UUID v4 to prevent payload injection
    if ! echo "$TEAM_MSG_REPLY_TO" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'; then
        echo "Error: TEAM_MSG_REPLY_TO must be a valid UUID v4 or 'null'" >&2
        exit 2
    fi
    REPLY_TO_JSON="\"${TEAM_MSG_REPLY_TO}\""
fi

# Build payload JSON
PAYLOAD=$(jq -n \
    --arg id "$MSG_ID" \
    --arg ts "$NOW_ISO" \
    --argjson sender_bit "$MY_BIT" \
    --arg sender_name "$MY_NAME" \
    --argjson sender_pid "$MY_PID" \
    --argjson sender_start "$MY_START_TIME" \
    --arg target "$TARGET" \
    --arg type "$MSG_TYPE" \
    --arg body "$BODY" \
    --arg priority "$TEAM_MSG_PRIORITY" \
    --argjson ttl "$TEAM_MSG_TTL" \
    --argjson reply_to "$REPLY_TO_JSON" \
    '{
        "id": $id,
        "timestamp": $ts,
        "sender": {
            "bit": $sender_bit,
            "name": $sender_name,
            "pid": $sender_pid,
            "start_time": $sender_start
        },
        "target": $target,
        "type": $type,
        "body": $body,
        "metadata": {
            "priority": $priority,
            "ttl_seconds": $ttl
        },
        "in_reply_to": $reply_to
    }')

# Write-to-tmp-then-rename (§5.3)
MESSAGES_DIR="${TEAM_QUEUE_DIR}/messages"
mkdir -p "$MESSAGES_DIR"
TMP_DIR="${MESSAGES_DIR}/.tmp-${MSG_ID}"

if ! mkdir "$TMP_DIR" 2>/dev/null; then
    echo "Error: failed to create staging directory $TMP_DIR" >&2
    exit 12
fi

# Cleanup tmp dir on error
trap 'rm -rf "$TMP_DIR" 2>/dev/null || true' ERR

mkdir "${TMP_DIR}/ack"
echo "$PAYLOAD" | jq '.' > "${TMP_DIR}/payload.json"
echo "$REQUIRED" > "${TMP_DIR}/required"

# Atomic publish
mv "$TMP_DIR" "${MESSAGES_DIR}/${MSG_ID}"

trap - ERR

RECIPIENT_COUNT=$(echo "$REGISTRY" | jq \
    --argjson req "$REQUIRED" \
    '[.sessions | to_entries[] | select(($req / pow(2; .value.bit) | floor) % 2 == 1)] | length')
echo "Sent ${MSG_TYPE} to '${TARGET}' (${RECIPIENT_COUNT} recipient(s)): ${MSG_ID}" >&2
echo "$MSG_ID"
exit 0
