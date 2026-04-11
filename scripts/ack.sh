#!/usr/bin/env bash
set -euo pipefail

# ack.sh <msg-id>
# Acknowledges a message by creating an ack file. Idempotent.
# Exit codes: 0=ok, 4=message not found, 5=not a recipient, 10=not registered

TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"
# shellcheck source=_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <msg-id>" >&2
    exit 2
fi

MSG_ID="$1"

# Validate UUID v4 format
if ! echo "$MSG_ID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'; then
    echo "Error: msg-id must be a valid UUID v4" >&2
    exit 2
fi

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

MSG_DIR="${TEAM_QUEUE_DIR}/messages/${MSG_ID}"

# Verify message exists
if [ ! -d "$MSG_DIR" ]; then
    echo "Error: message '$MSG_ID' not found" >&2
    exit 4
fi

# Verify caller is a required reader
REQUIRED_FILE="${MSG_DIR}/required"
if [ ! -f "$REQUIRED_FILE" ]; then
    echo "Error: message '$MSG_ID' not found (required file missing)" >&2
    exit 4
fi
REQUIRED_INT=$(cat "$REQUIRED_FILE")
BIT_IN_REQUIRED=$(( (REQUIRED_INT >> MY_BIT) & 1 ))
if [ "$BIT_IN_REQUIRED" -eq 0 ]; then
    echo "Error: this session (bit $MY_BIT) is not a recipient of message '$MSG_ID'" >&2
    exit 5
fi

# Create ack file — idempotent (O_CREAT semantics via touch)
mkdir -p "${MSG_DIR}/ack"
touch "${MSG_DIR}/ack/${MY_BIT}"

echo "Acked message '${MSG_ID}' (bit ${MY_BIT})" >&2
exit 0
