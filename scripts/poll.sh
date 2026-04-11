#!/usr/bin/env bash
set -euo pipefail

# poll.sh
# Scans messages/ and returns unacked messages targeting this session as a JSON array.
# Exit codes: 0=messages found, 1=no messages, 10=not registered/corrupt

TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"
# shellcheck source=_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

if [ -n "${TEAM_SESSION_BIT:-}" ]; then
    MY_BIT="$TEAM_SESSION_BIT"
else
    BIT_FILE="${TEAM_QUEUE_DIR}/.sessions/${SESSION_PID}.bit"
    if [ ! -f "$BIT_FILE" ]; then
        echo "Error: session not registered. Run 'bash scripts/register.sh <name>' first." >&2
        exit 10
    fi
    MY_BIT=$(cat "$BIT_FILE")
fi

MESSAGES_DIR="${TEAM_QUEUE_DIR}/messages"
if [ ! -d "$MESSAGES_DIR" ]; then
    echo "[]"
    exit 1
fi

# Collect matching message payloads into a temp file (one JSON object per line)
RESULTS_FILE=$(mktemp "${TMPDIR:-/tmp}/poll_results_$$.XXXXXX")
trap 'rm -f "$RESULTS_FILE"' EXIT

for entry in "${MESSAGES_DIR}"/*/; do
    # Skip if glob didn't match anything
    [ -e "$entry" ] || continue

    # Get the directory name (strip trailing slash)
    msg_id="${entry%/}"
    msg_id="${msg_id##*/}"

    # Skip dotfiles and .tmp-* staging dirs (§5.4)
    case "$msg_id" in
        .*) continue ;;
    esac

    # Validate msg_id is a UUID — prevents path traversal via crafted directory names
    case "$msg_id" in
        *[!/0-9a-f-]*) continue ;;
    esac

    msg_dir="${MESSAGES_DIR}/${msg_id}"

    # Read required mask — handle ENOENT from concurrent GC (§5.4)
    required_file="${msg_dir}/required"
    if [ ! -f "$required_file" ]; then
        continue  # Message deleted mid-scan
    fi
    required_int=$(cat "$required_file" 2>/dev/null) || continue
    # Validate it's a number
    case "$required_int" in
        ''|*[!0-9]*) continue ;;
    esac

    # Check if our bit is in the required mask
    bit_in_required=$(( (required_int >> MY_BIT) & 1 ))
    if [ "$bit_in_required" -eq 0 ]; then
        continue  # Not a recipient
    fi

    # Check if already acked
    if [ -f "${msg_dir}/ack/${MY_BIT}" ]; then
        continue  # Already read
    fi

    # Read payload — handle ENOENT from concurrent GC
    payload_file="${msg_dir}/payload.json"
    if [ ! -f "$payload_file" ]; then
        continue  # Concurrent GC
    fi
    payload=$(jq '.' "$payload_file" 2>/dev/null) || continue

    # Append to results (one JSON object per line)
    echo "$payload" >> "$RESULTS_FILE"
done

# Check if we found any messages
if [ ! -s "$RESULTS_FILE" ]; then
    echo "[]"
    exit 1
fi

# Sort by timestamp ascending (oldest first) and output as JSON array
jq -s 'sort_by(.timestamp)' "$RESULTS_FILE"
exit 0
