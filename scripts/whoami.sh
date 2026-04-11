#!/usr/bin/env bash
set -uo pipefail

# whoami.sh
# Checks if this Claude session is registered and prints its name and bit.
# Uses _common.sh to resolve the Claude PID automatically.
# Exit codes: 0=registered (prints "name bit"), 1=not registered

TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"
# shellcheck source=_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# GC before checking — clean up dead sessions first
TEAM_SESSION_BIT="${TEAM_SESSION_BIT:-0}" bash "$(dirname "${BASH_SOURCE[0]}")/gc.sh" 2>/dev/null || true
sleep 1

BIT_FILE="${TEAM_QUEUE_DIR}/.sessions/${SESSION_PID}.bit"

if [ ! -f "$BIT_FILE" ]; then
    echo "not-registered"
    exit 1
fi

MY_BIT=$(cat "$BIT_FILE")
MY_NAME=$(jq -r --argjson b "$MY_BIT" \
    '[.sessions | to_entries[] | select(.value.bit == $b) | .key] | first // "unknown"' \
    "${TEAM_QUEUE_DIR}/registry.json" 2>/dev/null)

echo "${MY_NAME} ${MY_BIT}"
exit 0
