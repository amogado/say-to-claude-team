#!/usr/bin/env bash
# _common.sh — Shared helpers for say-to-claude-team scripts
# Source this file: . "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Resolve the Claude Code session PID by walking up the process tree.
# Priority: TEAM_SESSION_PID env var > process tree walk > $PPID fallback
resolve_session_pid() {
    # Explicit override
    if [ -n "${TEAM_SESSION_PID:-}" ]; then
        echo "$TEAM_SESSION_PID"
        return
    fi

    # Walk up the process tree to find the nearest 'claude' ancestor
    local pid=$$
    while [ "$pid" -gt 1 ]; do
        local parent
        parent=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d " ")
        [ -z "$parent" ] && break
        local comm
        comm=$(ps -p "$parent" -o comm= 2>/dev/null)
        if [ "$comm" = "claude" ]; then
            echo "$parent"
            return
        fi
        pid="$parent"
    done

    # Fallback: PPID (works when Claude directly spawns the script)
    echo "$PPID"
}

SESSION_PID="$(resolve_session_pid)"
