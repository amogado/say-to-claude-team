#!/usr/bin/env bash
set -uo pipefail
# statusline-team-queue.sh — Team Queue status for Claude Code statusline
# Source this from statusline-command.sh: . ~/.claude/skills/say-to-claude-team/scripts/statusline-team-queue.sh
# Sets $team_queue variable with the status string.

team_queue=""
TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"

if [ -d "$TEAM_QUEUE_DIR" ]; then
    _my_bit=""; _my_name=""; _pid=""

    # Find OUR claude parent by walking up the process tree
    _walk_pid=$$
    _my_claude_pid=""
    while [ "$_walk_pid" -gt 1 ]; do
        _parent=$(ps -p "$_walk_pid" -o ppid= 2>/dev/null | tr -d " ")
        [ -z "$_parent" ] && break
        _comm=$(ps -p "$_parent" -o comm= 2>/dev/null)
        if [ "$_comm" = "claude" ]; then
            _my_claude_pid="$_parent"
            break
        fi
        _walk_pid="$_parent"
    done

    # Look up our bit from our specific claude PID
    if [ -n "$_my_claude_pid" ] && [ -f "$TEAM_QUEUE_DIR/.sessions/${_my_claude_pid}.bit" ]; then
        _pid="$_my_claude_pid"
        _my_bit=$(cat "$TEAM_QUEUE_DIR/.sessions/${_my_claude_pid}.bit")
        _my_name=$(jq -r --argjson b "$_my_bit" \
            '[.sessions | to_entries[] | select(.value.bit == $b) | .key] | first // "?"' \
            "$TEAM_QUEUE_DIR/registry.json" 2>/dev/null)
    fi

    if [ -n "$_my_bit" ]; then
        # Count unread messages
        _unread=0; _my_mask=$((1 << _my_bit))
        for msg_dir in "$TEAM_QUEUE_DIR/messages"/*/; do
            [ -d "$msg_dir" ] || continue
            _mid=$(basename "$msg_dir"); [[ "$_mid" == .* ]] && continue
            _req=$(cat "$msg_dir/required" 2>/dev/null) || continue
            if (( (_req & _my_mask) != 0 )) && [ ! -f "$msg_dir/ack/$_my_bit" ]; then
                _unread=$((_unread + 1))
            fi
        done

        # Count sessions
        _total_sessions=$(jq '.sessions | length' "$TEAM_QUEUE_DIR/registry.json" 2>/dev/null || echo 0)

        # Heartbeat age
        _hb_file="$TEAM_QUEUE_DIR/.sessions/${_pid}.heartbeat"; _hb_age=""
        if [ -f "$_hb_file" ]; then
            _hb_epoch=$(stat -f "%m" "$_hb_file" 2>/dev/null || echo 0)
            _now=$(date +%s); _hb_secs=$((_now - _hb_epoch))
            if [ "$_hb_secs" -lt 60 ]; then _hb_age="${_hb_secs}s"
            elif [ "$_hb_secs" -lt 3600 ]; then _hb_age="$((_hb_secs / 60))m"
            else _hb_age="$((_hb_secs / 3600))h"; fi
        fi

        # Build string
        team_queue="TQ: $_my_name(b$_my_bit)"
        if [ "$_unread" -gt 0 ]; then team_queue+=" ${_unread}msg"; fi
        team_queue+=" ${_total_sessions}sess"
        if [ -n "$_hb_age" ]; then team_queue+=" hb:${_hb_age}"; fi
    else
        team_queue="TQ: not registered"
    fi
fi
