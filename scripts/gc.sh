#!/usr/bin/env bash
set -euo pipefail

# gc.sh
# Garbage-collects fully-acked messages, expired messages, orphaned staging dirs,
# and dead sessions. Outputs count of deleted messages on stdout.
# Exit codes: 0=ok, 10=corrupt registry, 11=lock failure

TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"
TEAM_STALE_THRESHOLD="${TEAM_STALE_THRESHOLD:-300}"
TEAM_TMP_MAX_AGE="${TEAM_TMP_MAX_AGE:-60}"

MESSAGES_DIR="${TEAM_QUEUE_DIR}/messages"
REGISTRY_FILE="${TEAM_QUEUE_DIR}/registry.json"
LOCK_FILE="${TEAM_QUEUE_DIR}/registry.lock"

DELETED_COUNT=0
NOW=$(date +%s)

# ── Phase 1: Clean messages and orphaned .tmp-* dirs ──

if [ -d "$MESSAGES_DIR" ]; then
    # Phase 1b: Clean orphaned .tmp-* staging dirs (separate loop — bash glob */ skips dotfiles)
    for tmp_entry in "${MESSAGES_DIR}"/.tmp-*/; do
        [ -d "$tmp_entry" ] || continue
        mtime=$(stat -f "%m" "$tmp_entry" 2>/dev/null) || continue
        age=$(( NOW - mtime ))
        if [ "$age" -gt "$TEAM_TMP_MAX_AGE" ]; then
            echo "GC: removing orphaned staging dir: $tmp_entry (age ${age}s)" >&2
            rm -rf "$tmp_entry"
            DELETED_COUNT=$(( DELETED_COUNT + 1 ))
        fi
    done

    # Phase 1a: Clean fully-acked and expired messages
    for entry in "${MESSAGES_DIR}"/*/; do
        [ -e "$entry" ] || continue
        msg_id="${entry%/}"
        msg_id="${msg_id##*/}"

        # Skip any remaining dotfiles
        case "$msg_id" in
            .*) continue ;;
        esac

        msg_dir="${MESSAGES_DIR}/${msg_id}"

        # Read required — handle ENOENT from concurrent GC
        required_file="${msg_dir}/required"
        [ -f "$required_file" ] || continue
        required_int=$(cat "$required_file" 2>/dev/null) || continue
        case "$required_int" in ''|*[!0-9]*) continue ;; esac

        # Compute ack_mask by OR-reduction of ack files (§2.1)
        ack_mask=0
        ack_dir="${msg_dir}/ack"
        if [ -d "$ack_dir" ]; then
            for ack_entry in "${ack_dir}"/*; do
                [ -e "$ack_entry" ] || continue
                bit="${ack_entry##*/}"
                case "$bit" in ''|*[!0-9]*) continue ;; esac
                ack_mask=$(( ack_mask | (1 << bit) ))
            done
        fi

        # Check full ack: ack_mask & required == required  (§2.4)
        fully_acked=false
        if [ $(( ack_mask & required_int )) -eq "$required_int" ]; then
            fully_acked=true
        fi

        # Check TTL expiry (§2.6.2)
        expired=false
        payload_file="${msg_dir}/payload.json"
        if [ -f "$payload_file" ]; then
            ttl=$(jq -r '.metadata.ttl_seconds // 3600' "$payload_file" 2>/dev/null) || ttl=3600
            case "$ttl" in ''|*[!0-9]*) ttl=3600 ;; esac
            ts=$(jq -r '.timestamp' "$payload_file" 2>/dev/null) || ts=""
            if [ -n "$ts" ]; then
                # Convert ISO 8601 to epoch
                msg_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s" 2>/dev/null) || msg_epoch=0
                if [ "$msg_epoch" -gt 0 ]; then
                    age=$(( NOW - msg_epoch ))
                    if [ "$age" -gt "$ttl" ]; then
                        expired=true
                    fi
                fi
            fi
        fi

        if $fully_acked || $expired; then
            reason="fully-acked"
            $expired && ! $fully_acked && reason="TTL expired"
            echo "GC: removing message $msg_id ($reason)" >&2
            rm -rf "$msg_dir"
            DELETED_COUNT=$(( DELETED_COUNT + 1 ))
        fi
    done
fi

# ── Phase 2: Reap dead sessions (under lock) ──

if [ -f "$REGISTRY_FILE" ]; then
    touch "$LOCK_FILE"

    _RC=$(mktemp "${TMPDIR:-/tmp}/gc_rc_$$.XXXXXX")
    echo "11" > "$_RC"
    _INNER=$(mktemp "${TMPDIR:-/tmp}/gc_inner_$$.XXXXXX")
    trap 'rm -f "$_RC" "$_INNER"' EXIT

    # Pass variables via environment to avoid shell injection through heredoc expansion
    export _GC_QUEUE="$TEAM_QUEUE_DIR"
    export _GC_STALE_THRESHOLD="$TEAM_STALE_THRESHOLD"
    export _GC_RC="$_RC"
    export _GC_NOW="$NOW"

    # Quoted heredoc ('INNEREOF') prevents variable expansion — security fix
    cat > "$_INNER" << 'INNEREOF'
#!/usr/bin/env bash
set -euo pipefail
QUEUE="$_GC_QUEUE"
STALE_THRESHOLD="$_GC_STALE_THRESHOLD"
RC_FILE="$_GC_RC"
REG_FILE="${QUEUE}/registry.json"
NOW="$_GC_NOW"

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

if ! REGISTRY=$(jq '.' "$REG_FILE" 2>/dev/null); then
    fail "Error: registry.json is corrupt" 10
fi

# Check each session for liveness
NAMES=$(echo "$REGISTRY" | jq -r '.sessions | keys[]')
for name in $NAMES; do
    session_pid=$(echo "$REGISTRY" | jq -r --arg n "$name" '.sessions[$n].pid')
    session_start=$(echo "$REGISTRY" | jq -r --arg n "$name" '.sessions[$n].start_time')
    session_hb=$(echo "$REGISTRY" | jq -r --arg n "$name" '.sessions[$n].last_heartbeat')
    session_bit=$(echo "$REGISTRY" | jq -r --arg n "$name" '.sessions[$n].bit')
    is_dead=false
    pid_dead=false
    hb_stale=false

    # PID liveness check + start_time validation (mitigates PID recycling)
    if ! kill -0 "$session_pid" 2>/dev/null; then
        pid_dead=true
    else
        actual_start=$(get_start_time "$session_pid")
        if [ "$actual_start" != "$session_start" ] && [ "$actual_start" != "0" ]; then
            pid_dead=true  # PID recycled to a different process
        fi
    fi

    # Heartbeat staleness check (always run, independent of PID check)
    hb_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$session_hb" "+%s" 2>/dev/null) || hb_epoch=0
    if [ "$hb_epoch" -gt 0 ]; then
        hb_age=$(( NOW - hb_epoch ))
        if [ "$hb_age" -gt "$STALE_THRESHOLD" ]; then
            hb_stale=true
        fi
    else
        hb_stale=true  # Can't parse heartbeat — assume stale
    fi

    # PID dead → reap immediately (process is gone, no reason to wait).
    # PID alive → never reap (even if heartbeat is stale).
    if $pid_dead; then
        is_dead=true
    fi

    if $is_dead; then
        echo "GC: reaping dead session '$name' (PID $session_pid, bit $session_bit)" >&2
        REGISTRY=$(echo "$REGISTRY" | jq \
            --arg n "$name" --argjson bit "$session_bit" \
            'del(.sessions[$n]) | .recycled_bits += [$bit]')
        rm -f "${QUEUE}/.sessions/${session_pid}.bit"
        rm -f "${QUEUE}/.sessions/${session_pid}.start_time"
    fi
done

# Deduplicate: if multiple sessions share the same PID, keep only the most recent one
DUP_PIDS=$(echo "$REGISTRY" | jq -r '[.sessions | to_entries[] | .value.pid] | group_by(.) | map(select(length > 1)) | .[0][0] // empty')
if [ -n "$DUP_PIDS" ]; then
    for dup_pid in $DUP_PIDS; do
        # Get all entries for this PID, sorted by registered_at (keep newest)
        ENTRIES=$(echo "$REGISTRY" | jq -r --argjson p "$dup_pid" \
            '[.sessions | to_entries[] | select(.value.pid == $p)] | sort_by(.value.registered_at) | .[:-1] | .[].key')
        for old_name in $ENTRIES; do
            old_bit=$(echo "$REGISTRY" | jq -r --arg n "$old_name" '.sessions[$n].bit')
            echo "GC: removing duplicate session '$old_name' (PID $dup_pid, bit $old_bit — same PID as another session)" >&2
            REGISTRY=$(echo "$REGISTRY" | jq \
                --arg n "$old_name" --argjson bit "$old_bit" \
                'del(.sessions[$n]) | .recycled_bits += [$bit]')
        done
    done
fi

TMP_REG=$(mktemp "${QUEUE}/registry.json.XXXXXX")
echo "$REGISTRY" | jq '.' > "$TMP_REG"
mv "$TMP_REG" "$REG_FILE"
echo "0" > "$RC_FILE"
INNEREOF

    chmod +x "$_INNER"

    lockf -k -t 5 "$LOCK_FILE" bash "$_INNER" || true

    LOCK_RC=$(cat "$_RC")
    case "$LOCK_RC" in
        0)  ;;
        10) echo "Error: registry.json is corrupt" >&2; exit 10 ;;
        *)  echo "Error: failed to acquire registry lock" >&2; exit 11 ;;
    esac
fi

echo "$DELETED_COUNT"
exit 0
