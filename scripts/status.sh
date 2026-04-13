#!/usr/bin/env bash
set -euo pipefail

# status.sh
# Displays human-readable queue status: sessions, messages, acks pending.
# Exit codes: 0=ok, 10=corrupt registry

TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"

REGISTRY_FILE="${TEAM_QUEUE_DIR}/registry.json"
MESSAGES_DIR="${TEAM_QUEUE_DIR}/messages"

# Read registry (snapshot read — no lock needed)
if [ ! -f "$REGISTRY_FILE" ]; then
    echo "Queue directory: ${TEAM_QUEUE_DIR}"
    echo "Registry: not initialized"
    echo ""
    echo "Sessions: 0"
    echo "Messages: 0"
    exit 0
fi

if ! REGISTRY=$(jq '.' "$REGISTRY_FILE" 2>/dev/null); then
    echo "Error: registry.json is corrupt" >&2
    exit 10
fi

NOW=$(date +%s)

echo "=== Team Queue Status ==="
echo "Queue dir:  ${TEAM_QUEUE_DIR}"
echo ""

# Sessions
SESSION_COUNT=$(echo "$REGISTRY" | jq '.sessions | length')
echo "--- Sessions (${SESSION_COUNT} registered) ---"

if [ "$SESSION_COUNT" -gt 0 ]; then
    SESSIONS_DIR="${TEAM_QUEUE_DIR}/.sessions"
    echo "$REGISTRY" | jq -r '.sessions | to_entries[] | "\(.key)\t\(.value.bit)\t\(.value.pid)\t\(.value.mode // "autonomous")\t\(.value.summary // "")"' | while IFS=$'\t' read -r name bit pid mode summary; do
        # Heartbeat from .sessions/<PID>.heartbeat file mtime
        hb_file="${SESSIONS_DIR}/${pid}.heartbeat"
        if [ -f "$hb_file" ]; then
            hb_epoch=$(stat -f "%m" "$hb_file" 2>/dev/null || echo 0)
            age=$((NOW - hb_epoch))
            if [ "$age" -lt 60 ]; then hb_rel="${age}s ago"
            elif [ "$age" -lt 3600 ]; then hb_rel="$((age / 60))m ago"
            else hb_rel="$((age / 3600))h ago"; fi
        else
            hb_rel="no heartbeat"
        fi
        mode_tag=""
        if [ "$mode" = "human-only" ]; then
            mode_tag="  [HUMAN-ONLY]"
        fi
        summary_tag=""
        if [ -n "$summary" ]; then
            summary_tag="  -- ${summary}"
        fi
        echo "  ${name}  bit=${bit}  pid=${pid}  heartbeat=${hb_rel}${mode_tag}${summary_tag}"
    done
fi
echo ""

# Messages
echo "--- Messages ---"
if [ ! -d "$MESSAGES_DIR" ]; then
    echo "  messages/ directory not found"
    echo ""
    exit 0
fi

total_msgs=0
fully_acked=0
pending=0
expired=0

for entry in "${MESSAGES_DIR}"/*/; do
    [ -e "$entry" ] || continue
    msg_id="${entry%/}"
    msg_id="${msg_id##*/}"

    # Skip dotfiles / staging dirs
    case "$msg_id" in .*) continue ;; esac

    msg_dir="${MESSAGES_DIR}/${msg_id}"
    total_msgs=$(( total_msgs + 1 ))

    required_file="${msg_dir}/required"
    [ -f "$required_file" ] || continue
    required_int=$(cat "$required_file" 2>/dev/null) || continue

    # Compute ack_mask
    ack_mask=0
    if [ -d "${msg_dir}/ack" ]; then
        for ack_entry in "${msg_dir}/ack"/*; do
            [ -e "$ack_entry" ] || continue
            bit="${ack_entry##*/}"
            case "$bit" in ''|*[!0-9]*) continue ;; esac
            ack_mask=$(( ack_mask | (1 << bit) ))
        done
    fi

    if [ $(( ack_mask & required_int )) -eq "$required_int" ]; then
        fully_acked=$(( fully_acked + 1 ))
        continue
    fi

    # Check TTL
    is_expired=false
    payload_file="${msg_dir}/payload.json"
    if [ -f "$payload_file" ]; then
        ttl=$(jq -r '.metadata.ttl_seconds // 3600' "$payload_file" 2>/dev/null) || ttl=3600
        ts=$(jq -r '.timestamp' "$payload_file" 2>/dev/null) || ts=""
        if [ -n "$ts" ]; then
            msg_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s" 2>/dev/null) || msg_epoch=0
            if [ "$msg_epoch" -gt 0 ] && [ $(( NOW - msg_epoch )) -gt "$ttl" ]; then
                is_expired=true
            fi
        fi
    fi

    if $is_expired; then
        expired=$(( expired + 1 ))
    else
        pending=$(( pending + 1 ))
        # Show pending message summary
        if [ -f "$payload_file" ]; then
            sender=$(jq -r '.sender.name // "?"' "$payload_file" 2>/dev/null)
            target=$(jq -r '.target' "$payload_file" 2>/dev/null)
            ts=$(jq -r '.timestamp' "$payload_file" 2>/dev/null)
            type=$(jq -r '.type' "$payload_file" 2>/dev/null)
            # Compute how many acks are still missing
            pending_bits=$(( required_int & ~ack_mask ))
            missing_count=0
            tmp_mask=$pending_bits
            while [ "$tmp_mask" -gt 0 ]; do
                missing_count=$(( missing_count + (tmp_mask & 1) ))
                tmp_mask=$(( tmp_mask >> 1 ))
            done
            echo "  [PENDING] ${msg_id:0:8}...  from=${sender}  to=${target}  type=${type}  sent=${ts}  waiting=${missing_count} ack(s)"
        fi
    fi
done

echo ""
echo "  Total:       ${total_msgs}"
echo "  Pending:     ${pending}"
echo "  Fully-acked: ${fully_acked}"
echo "  Expired:     ${expired}"
echo ""

# Orphaned staging dirs
TMP_COUNT=0
for entry in "${MESSAGES_DIR}"/.tmp-*/; do
    [ -e "$entry" ] || continue
    TMP_COUNT=$(( TMP_COUNT + 1 ))
done
if [ "$TMP_COUNT" -gt 0 ]; then
    echo "  WARNING: ${TMP_COUNT} orphaned staging dir(s) found (run gc.sh to clean)"
    echo ""
fi

exit 0
