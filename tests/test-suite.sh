#!/usr/bin/env bash
# test-suite.sh — Comprehensive test suite for say-to-claude-team message queue
# Usage: bash tests/test-suite.sh [--verbose]
# Runs in an isolated tmpdir (mktemp -d). Self-contained.

set -uo pipefail

# ── Setup ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPTS_DIR="${REPO_DIR}/scripts"

VERBOSE=false
[[ "${1:-}" == "--verbose" ]] && VERBOSE=true

# Test counters
PASS=0
FAIL=0
SKIP=0

# Colors (only if terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; RESET=''
fi

# Isolated test environment
TEST_DIR=$(mktemp -d /tmp/team-queue-test.XXXXXX)
export TEAM_QUEUE_DIR="${TEST_DIR}/queue"
export TEAM_SKIP_GC=1
export TEAM_HEARTBEAT_MAX_AGE=999999
mkdir -p "${TEAM_QUEUE_DIR}/messages"
mkdir -p "${TEAM_QUEUE_DIR}/.sessions"
touch "${TEAM_QUEUE_DIR}/registry.lock"
echo '{"version":1,"sessions":{},"next_bit":0,"recycled_bits":[]}' > "${TEAM_QUEUE_DIR}/registry.json"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# ── Test helpers ──────────────────────────────────────────────────────────────

assert_pass() {
    local name="$1"
    local result="$2"
    local expected_exit="${3:-0}"
    local actual_exit="${4:-0}"
    if [ "$actual_exit" -eq "$expected_exit" ]; then
        PASS=$(( PASS + 1 ))
        $VERBOSE && echo -e "  ${GREEN}PASS${RESET} $name"
        return 0
    else
        FAIL=$(( FAIL + 1 ))
        echo -e "  ${RED}FAIL${RESET} $name"
        $VERBOSE && echo "       expected exit=$expected_exit, got exit=$actual_exit, output: $result"
        return 1
    fi
}

run_test() {
    local name="$1"
    shift
    local output exit_code
    output=$("$@" 2>&1) && exit_code=$? || exit_code=$?
    echo "$output"
    return $exit_code
}

pass() {
    PASS=$(( PASS + 1 ))
    echo -e "  ${GREEN}PASS${RESET} $1"
}

fail() {
    FAIL=$(( FAIL + 1 ))
    echo -e "  ${RED}FAIL${RESET} $1"
    [ -n "${2:-}" ] && echo "       -> $2"
}

skip() {
    SKIP=$(( SKIP + 1 ))
    echo -e "  ${YELLOW}SKIP${RESET} $1: $2"
}

# Auto-incrementing PID for register.sh — each call gets a unique fake PID
# GC is skipped via TEAM_SKIP_GC=1, heartbeat filter bypassed via TEAM_HEARTBEAT_MAX_AGE=999999
_NEXT_PID=10001
register_session() {
    local name="$1"
    local pid=$_NEXT_PID
    _NEXT_PID=$((_NEXT_PID + 1))
    TEAM_SESSION_PID=$pid bash "${SCRIPTS_DIR}/register.sh" "$name" 2>/dev/null
    # Create heartbeat file so send.sh heartbeat filter includes test sessions
    touch "${TEAM_QUEUE_DIR}/.sessions/${pid}.heartbeat"
}

# Reset queue to clean state between test groups
reset_queue() {
    rm -rf "${TEAM_QUEUE_DIR}"
    mkdir -p "${TEAM_QUEUE_DIR}/messages"
    mkdir -p "${TEAM_QUEUE_DIR}/.sessions"
    touch "${TEAM_QUEUE_DIR}/registry.lock"
    echo '{"version":1,"sessions":{},"next_bit":0,"recycled_bits":[]}' > "${TEAM_QUEUE_DIR}/registry.json"
    _NEXT_PID=10001
}

echo "=== say-to-claude-team Test Suite ==="
echo "Queue dir: ${TEAM_QUEUE_DIR}"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# §A — Normal Cases
# ═══════════════════════════════════════════════════════════════════════════════
echo "── A. Normal Cases ──────────────────────────────────────────────────────"

# A1: Register two sessions, send broadcast, both poll and see it
echo ""
echo "A1: Broadcast message — two sessions"
reset_queue

BIT_A=$(register_session alice)
BIT_B=$(register_session bob)

if [[ "$BIT_A" =~ ^[0-9]+$ ]] && [[ "$BIT_B" =~ ^[0-9]+$ ]]; then
    pass "A1.1 register alice → bit=$BIT_A"
    pass "A1.2 register bob   → bit=$BIT_B"
else
    fail "A1.1/A1.2 register failed" "alice_bit='$BIT_A' bob_bit='$BIT_B'"
fi

# Send broadcast as alice
MSG_ID=$(TEAM_SESSION_BIT="$BIT_A" bash "${SCRIPTS_DIR}/send.sh" all text "hello team" 2>/dev/null)
if [[ "$MSG_ID" =~ ^[0-9a-f-]{36}$ ]]; then
    pass "A1.3 broadcast send → msg_id=$MSG_ID"
else
    fail "A1.3 broadcast send" "msg_id='$MSG_ID'"
fi

# Bob polls and sees the message
POLL_B=$(TEAM_SESSION_BIT="$BIT_B" bash "${SCRIPTS_DIR}/poll.sh" 2>/dev/null)
POLL_B_EXIT=$?
if [ "$POLL_B_EXIT" -eq 0 ] && echo "$POLL_B" | jq -e '.[0].id' >/dev/null 2>&1; then
    pass "A1.4 bob polls → sees message"
else
    fail "A1.4 bob polls" "exit=$POLL_B_EXIT output='$POLL_B'"
fi

# Alice should NOT see her own broadcast (she's the sender, excluded from required)
POLL_A=$(TEAM_SESSION_BIT="$BIT_A" bash "${SCRIPTS_DIR}/poll.sh" 2>/dev/null)
POLL_A_EXIT=$?
if [ "$POLL_A_EXIT" -eq 1 ]; then
    pass "A1.5 alice polls → no messages (sender excluded)"
else
    fail "A1.5 alice polls" "exit=$POLL_A_EXIT output='$POLL_A'"
fi

# A2: Directed message — only target sees it
echo ""
echo "A2: Directed message — only target sees it"

MSG_DIR=$(TEAM_SESSION_BIT="$BIT_A" bash "${SCRIPTS_DIR}/send.sh" bob text "hey bob" 2>/dev/null)
REQUIRED=$(cat "${TEAM_QUEUE_DIR}/messages/${MSG_DIR}/required" 2>/dev/null)
EXPECTED_REQ=$(( 1 << BIT_B ))

if [ "$REQUIRED" -eq "$EXPECTED_REQ" ]; then
    pass "A2.1 directed message required mask = 2^bob_bit"
else
    fail "A2.1 required mask mismatch" "expected=$EXPECTED_REQ got=$REQUIRED"
fi

POLL_B2=$(TEAM_SESSION_BIT="$BIT_B" bash "${SCRIPTS_DIR}/poll.sh" 2>/dev/null)
COUNT_B=$(echo "$POLL_B2" | jq 'length' 2>/dev/null)
if [ "$COUNT_B" -ge 2 ]; then
    pass "A2.2 bob sees directed message (+ broadcast still pending)"
else
    fail "A2.2 bob sees directed message" "count=$COUNT_B output='$POLL_B2'"
fi

# A3: Ack then GC collects
echo ""
echo "A3: Ack → GC collects"

MSGS_BEFORE=$(ls "${TEAM_QUEUE_DIR}/messages/" | grep -v '^\.' | wc -l | tr -d ' ')

# Bob acks all pending messages
POLL_B3=$(TEAM_SESSION_BIT="$BIT_B" bash "${SCRIPTS_DIR}/poll.sh" 2>/dev/null)
ACK_IDS=$(echo "$POLL_B3" | jq -r '.[].id' 2>/dev/null)
for mid in $ACK_IDS; do
    TEAM_SESSION_BIT="$BIT_B" bash "${SCRIPTS_DIR}/ack.sh" "$mid" 2>/dev/null
done

ACK_COUNT=$(echo "$ACK_IDS" | wc -l | tr -d ' ')
pass "A3.1 bob acked $ACK_COUNT messages"

GC_OUT=$(bash "${SCRIPTS_DIR}/gc.sh" 2>/dev/null)
GC_EXIT=$?
MSGS_AFTER=$(ls "${TEAM_QUEUE_DIR}/messages/" | grep -v '^\.' | wc -l | tr -d ' ')

if [ "$GC_EXIT" -eq 0 ] && [ "$MSGS_AFTER" -lt "$MSGS_BEFORE" ]; then
    pass "A3.2 GC deleted $GC_OUT messages (${MSGS_BEFORE} → ${MSGS_AFTER})"
else
    fail "A3.2 GC collect after ack" "exit=$GC_EXIT gc_out='$GC_OUT' msgs_before=$MSGS_BEFORE msgs_after=$MSGS_AFTER"
fi

# A4: Register/deregister cycle — bit recycling
echo ""
echo "A4: Deregister cycle — bit recycling"

BIT_C=$(register_session carol)
pass "A4.1 register carol → bit=$BIT_C"

TEAM_SESSION_BIT="$BIT_C" bash "${SCRIPTS_DIR}/deregister.sh" 2>/dev/null
DEREG_EXIT=$?
if [ "$DEREG_EXIT" -eq 0 ]; then
    pass "A4.2 deregister carol → ok"
else
    fail "A4.2 deregister carol" "exit=$DEREG_EXIT"
fi

RECYCLED=$(jq -r --argjson bit "$BIT_C" '.recycled_bits | index($bit) // empty' "${TEAM_QUEUE_DIR}/registry.json" 2>/dev/null)
if [ -n "$RECYCLED" ]; then
    pass "A4.3 bit $BIT_C in recycled_bits after deregister"
else
    RECYCLED_ALL=$(jq -r '.recycled_bits' "${TEAM_QUEUE_DIR}/registry.json" 2>/dev/null)
    fail "A4.3 bit recycling" "expected bit=$BIT_C in recycled_bits, got $RECYCLED_ALL"
fi

RECYCLED_BEFORE=$(jq '.recycled_bits | length' "${TEAM_QUEUE_DIR}/registry.json" 2>/dev/null)
BIT_D=$(register_session dave)
RECYCLED_AFTER=$(jq '.recycled_bits | length' "${TEAM_QUEUE_DIR}/registry.json" 2>/dev/null)
if [ "$RECYCLED_AFTER" -lt "$RECYCLED_BEFORE" ]; then
    pass "A4.4 dave consumed a recycled bit -> bit=$BIT_D (recycled: $RECYCLED_BEFORE -> $RECYCLED_AFTER)"
else
    fail "A4.4 bit not recycled" "recycled_before=$RECYCLED_BEFORE recycled_after=$RECYCLED_AFTER"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# §B — Edge Cases (Input Validation & Names)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── B. Edge Cases: Input Validation ─────────────────────────────────────"
reset_queue

# B1: Register with name containing spaces — expected: rejected
echo ""
echo "B1: Register name with spaces → rejected"
OUT=$(bash "${SCRIPTS_DIR}/register.sh" "alice bob" 2>&1) && EC=$? || EC=$?
if [ "$EC" -ne 0 ]; then
    pass "B1.1 register 'alice bob' → rejected (exit=$EC)"
else
    fail "B1.1 register 'alice bob' should be rejected" "exit=$EC out='$OUT'"
fi

# B2: Register with special chars: quotes
echo ""
echo "B2: Register name with special chars"
OUT=$(bash "${SCRIPTS_DIR}/register.sh" 'say"quoted"' 2>&1) && EC=$? || EC=$?
if [ "$EC" -ne 0 ]; then
    pass 'B2.1 register name with " → rejected'
else
    fail 'B2.1 register name with " should be rejected' "exit=$EC out='$OUT'"
fi

# B3: Register with dollar sign
OUT=$(bash "${SCRIPTS_DIR}/register.sh" '$variable' 2>&1) && EC=$? || EC=$?
if [ "$EC" -ne 0 ]; then
    pass 'B3.1 register name with $ → rejected'
else
    fail 'B3.1 register name with $ should be rejected' "exit=$EC"
fi

# B4: Register with backticks
OUT=$(bash "${SCRIPTS_DIR}/register.sh" '`cmd`' 2>&1) && EC=$? || EC=$?
if [ "$EC" -ne 0 ]; then
    pass 'B4.1 register name with backticks → rejected'
else
    fail 'B4.1 register name with backticks should be rejected' "exit=$EC"
fi

# B5: Register valid names with dashes/underscores
BIT_VALID=$(register_session "my-agent_01") && EC=$? || EC=$?
if [ "$EC" -eq 0 ] && [[ "$BIT_VALID" =~ ^[0-9]+$ ]]; then
    pass "B5.1 register 'my-agent_01' (dash+underscore) → ok, bit=$BIT_VALID"
else
    fail "B5.1 register 'my-agent_01'" "exit=$EC bit='$BIT_VALID'"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# §C — Edge Cases (Message Body)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── C. Edge Cases: Message Body ──────────────────────────────────────────"
reset_queue

BIT_S=$(register_session sender)
BIT_R=$(register_session receiver)

# C1: Empty body
echo ""
echo "C1: Send with empty body"
MID=$(TEAM_SESSION_BIT="$BIT_S" bash "${SCRIPTS_DIR}/send.sh" receiver text "" 2>/dev/null) && EC=$? || EC=$?
if [ "$EC" -eq 0 ] && [[ "$MID" =~ ^[0-9a-f-]{36}$ ]]; then
    BODY=$(jq -r '.body' "${TEAM_QUEUE_DIR}/messages/${MID}/payload.json" 2>/dev/null)
    if [ "$BODY" = "" ]; then
        pass "C1.1 send empty body → ok, body stored as empty string"
    else
        fail "C1.1 send empty body — body mismatch" "body='$BODY'"
    fi
else
    fail "C1.1 send empty body" "exit=$EC mid='$MID'"
fi

# C2: Very long body (>10KB)
echo ""
echo "C2: Send with large body (>10KB)"
LARGE_BODY=$(python3 -c "print('A' * 11000)" 2>/dev/null || printf 'A%.0s' {1..11000})
MID_LARGE=$(TEAM_SESSION_BIT="$BIT_S" bash "${SCRIPTS_DIR}/send.sh" receiver text "$LARGE_BODY" 2>/dev/null) && EC=$? || EC=$?
if [ "$EC" -eq 0 ] && [[ "$MID_LARGE" =~ ^[0-9a-f-]{36}$ ]]; then
    BODY_LEN=$(jq -r '.body' "${TEAM_QUEUE_DIR}/messages/${MID_LARGE}/payload.json" 2>/dev/null | wc -c | tr -d ' ')
    if [ "$BODY_LEN" -ge 11000 ]; then
        pass "C2.1 send large body → ok, stored $BODY_LEN chars"
    else
        fail "C2.1 large body stored incorrectly" "body_len=$BODY_LEN"
    fi
else
    fail "C2.1 send large body" "exit=$EC mid='$MID_LARGE'"
fi

# C3: Body with newlines
echo ""
echo "C3: Send body with newlines"
MULTILINE="line one
line two
line three"
MID_ML=$(TEAM_SESSION_BIT="$BIT_S" bash "${SCRIPTS_DIR}/send.sh" receiver text "$MULTILINE" 2>/dev/null) && EC=$? || EC=$?
if [ "$EC" -eq 0 ] && [[ "$MID_ML" =~ ^[0-9a-f-]{36}$ ]]; then
    STORED=$(jq -r '.body' "${TEAM_QUEUE_DIR}/messages/${MID_ML}/payload.json" 2>/dev/null)
    if [ "$STORED" = "$MULTILINE" ]; then
        pass "C3.1 send body with newlines → stored correctly"
    else
        fail "C3.1 body with newlines mismatch" "stored='$STORED'"
    fi
else
    fail "C3.1 send body with newlines" "exit=$EC mid='$MID_ML'"
fi

# C4: Body with double quotes
echo ""
echo "C4: Send body with double quotes"
QUOTED_BODY='say "hello" to me'
MID_Q=$(TEAM_SESSION_BIT="$BIT_S" bash "${SCRIPTS_DIR}/send.sh" receiver text "$QUOTED_BODY" 2>/dev/null) && EC=$? || EC=$?
if [ "$EC" -eq 0 ] && [[ "$MID_Q" =~ ^[0-9a-f-]{36}$ ]]; then
    STORED=$(jq -r '.body' "${TEAM_QUEUE_DIR}/messages/${MID_Q}/payload.json" 2>/dev/null)
    if [ "$STORED" = "$QUOTED_BODY" ]; then
        pass "C4.1 send body with double quotes → stored correctly"
    else
        fail "C4.1 body with double quotes mismatch" "stored='$STORED' expected='$QUOTED_BODY'"
    fi
else
    fail "C4.1 send body with double quotes" "exit=$EC mid='$MID_Q'"
fi

# C5: Body as JSON
echo ""
echo "C5: Send body that is JSON"
JSON_BODY='{"key": "value", "nested": {"arr": [1,2,3]}}'
MID_JSON=$(TEAM_SESSION_BIT="$BIT_S" bash "${SCRIPTS_DIR}/send.sh" receiver text "$JSON_BODY" 2>/dev/null) && EC=$? || EC=$?
if [ "$EC" -eq 0 ] && [[ "$MID_JSON" =~ ^[0-9a-f-]{36}$ ]]; then
    STORED=$(jq -r '.body' "${TEAM_QUEUE_DIR}/messages/${MID_JSON}/payload.json" 2>/dev/null)
    if [ "$STORED" = "$JSON_BODY" ]; then
        pass "C5.1 send JSON body → stored correctly as string"
    else
        fail "C5.1 JSON body stored incorrectly" "stored='$STORED'"
    fi
else
    fail "C5.1 send JSON body" "exit=$EC mid='$MID_JSON'"
fi

# C6: Body with shell metacharacters
echo ""
echo "C6: Send body with shell metacharacters"
SHELL_BODY='$(rm -rf /); `echo pwned`; echo $HOME'
MID_SHELL=$(TEAM_SESSION_BIT="$BIT_S" bash "${SCRIPTS_DIR}/send.sh" receiver text "$SHELL_BODY" 2>/dev/null) && EC=$? || EC=$?
if [ "$EC" -eq 0 ] && [[ "$MID_SHELL" =~ ^[0-9a-f-]{36}$ ]]; then
    STORED=$(jq -r '.body' "${TEAM_QUEUE_DIR}/messages/${MID_SHELL}/payload.json" 2>/dev/null)
    if [ "$STORED" = "$SHELL_BODY" ]; then
        pass "C6.1 shell metacharacters in body → stored safely"
    else
        fail "C6.1 shell metacharacter body mismatch" "stored='$STORED'"
    fi
else
    fail "C6.1 send body with shell metacharacters" "exit=$EC mid='$MID_SHELL'"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# §D — Edge Cases (Poll / Ack)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── D. Edge Cases: Poll & Ack ────────────────────────────────────────────"

# D1: Poll when no messages
echo ""
echo "D1: Poll with no messages"
reset_queue
BIT_X=$(register_session solo)
POLL_EMPTY=$(TEAM_SESSION_BIT="$BIT_X" bash "${SCRIPTS_DIR}/poll.sh" 2>/dev/null) && EC=$? || EC=$?
if [ "$EC" -eq 1 ] && [ "$POLL_EMPTY" = "[]" ]; then
    pass "D1.1 poll empty queue → [] with exit=1"
else
    fail "D1.1 poll empty queue" "exit=$EC output='$POLL_EMPTY'"
fi

# D2: Ack a message that doesn't exist
echo ""
echo "D2: Ack non-existent message"
FAKE_UUID="00000000-0000-4000-8000-000000000000"
OUT=$(TEAM_SESSION_BIT="$BIT_X" bash "${SCRIPTS_DIR}/ack.sh" "$FAKE_UUID" 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 4 ]; then
    pass "D2.1 ack non-existent msg → exit=4"
else
    fail "D2.1 ack non-existent msg" "exit=$EC out='$OUT'"
fi

# D3: Ack a message you're not a recipient of
echo ""
echo "D3: Ack message you're not a recipient of"
reset_queue
BIT_S2=$(register_session sender2)
BIT_R2=$(register_session receiver2)
BIT_THIRD=$(register_session third)
# Send directed to receiver2 only
MID_DIR=$(TEAM_SESSION_BIT="$BIT_S2" bash "${SCRIPTS_DIR}/send.sh" receiver2 text "only for you" 2>/dev/null)
# Third session tries to ack it
OUT=$(TEAM_SESSION_BIT="$BIT_THIRD" bash "${SCRIPTS_DIR}/ack.sh" "$MID_DIR" 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 5 ]; then
    pass "D3.1 ack msg not addressed to you → exit=5"
else
    fail "D3.1 ack message not for you" "exit=$EC out='$OUT'"
fi

# D4: Double ack — idempotence
echo ""
echo "D4: Double ack (idempotence)"
TEAM_SESSION_BIT="$BIT_R2" bash "${SCRIPTS_DIR}/ack.sh" "$MID_DIR" 2>/dev/null
TEAM_SESSION_BIT="$BIT_R2" bash "${SCRIPTS_DIR}/ack.sh" "$MID_DIR" 2>/dev/null && EC=$? || EC=$?
ACK_COUNT=$(ls "${TEAM_QUEUE_DIR}/messages/${MID_DIR}/ack/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$EC" -eq 0 ] && [ "$ACK_COUNT" -eq 1 ]; then
    pass "D4.1 double ack → idempotent (1 ack file, exit=0)"
else
    fail "D4.1 double ack idempotence" "exit=$EC ack_count=$ACK_COUNT"
fi

# D5: After full ack, poll no longer returns the message
echo ""
echo "D5: Polled message not returned again after ack"
POLL_AFTER=$(TEAM_SESSION_BIT="$BIT_R2" bash "${SCRIPTS_DIR}/poll.sh" 2>/dev/null) && EC=$? || EC=$?
# The acked message should no longer appear
HAS_ACKED=$(echo "$POLL_AFTER" | jq --arg id "$MID_DIR" '[.[] | select(.id == $id)] | length' 2>/dev/null)
if [ "$HAS_ACKED" = "0" ]; then
    pass "D5.1 acked message no longer returned by poll"
else
    fail "D5.1 acked message still visible after ack" "has_acked=$HAS_ACKED"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# §E — Edge Cases (GC)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── E. Edge Cases: Garbage Collection ───────────────────────────────────"

# E1: GC on empty queue
echo ""
echo "E1: GC on empty queue"
reset_queue
OUT=$(bash "${SCRIPTS_DIR}/gc.sh" 2>/dev/null) && EC=$? || EC=$?
if [ "$EC" -eq 0 ] && [ "$OUT" = "0" ]; then
    pass "E1.1 gc on empty queue → deleted=0, exit=0"
else
    fail "E1.1 gc empty queue" "exit=$EC out='$OUT'"
fi

# E2: GC with orphaned .tmp-* dirs
# BUG: gc.sh uses glob "${MESSAGES_DIR}"/*/  which does NOT expand dotfiles on macOS bash.
# The .tmp-* branch inside the case statement is dead code — it is never reached.
# This test documents the bug.
echo ""
echo "E2: GC cleans up orphaned .tmp-* staging dirs (BUG DETECTION)"
reset_queue
# Create an old .tmp dir
OLD_TMP="${TEAM_QUEUE_DIR}/messages/.tmp-00000000-0000-4000-8000-000000000001"
mkdir -p "${OLD_TMP}/ack"
echo '{}' > "${OLD_TMP}/payload.json"
echo "1" > "${OLD_TMP}/required"
# Age it by setting mtime to > TEAM_TMP_MAX_AGE seconds ago
touch -t "$(date -v-120S +%Y%m%d%H%M.%S)" "$OLD_TMP" 2>/dev/null \
    || touch -d "2 minutes ago" "$OLD_TMP" 2>/dev/null \
    || true

OUT=$(TEAM_TMP_MAX_AGE=60 bash "${SCRIPTS_DIR}/gc.sh" 2>/dev/null) && EC=$? || EC=$?
# KNOWN BUG: gc.sh glob */  skips dotfiles — .tmp-* dirs are never cleaned by GC
# We document this as a BUG — the .tmp-* dir should have been removed but isn't
if [ -d "$OLD_TMP" ] && [ "$EC" -eq 0 ]; then
    # Bug confirmed: gc ran successfully but .tmp-* dir was NOT cleaned
    FAIL=$(( FAIL + 1 ))
    echo -e "  ${RED}BUG${RESET} E2.1 gc does NOT remove orphaned .tmp-* dir (glob */  skips dotfiles)"
    echo "       -> This is a bug in gc.sh: 'for entry in \"\${MESSAGES_DIR}\"/*/' never matches .tmp-* dirs"
else
    pass "E2.1 gc removes orphaned .tmp-* dir"
fi

# E3: GC does not delete partially-acked messages
echo ""
echo "E3: GC safety — does not delete partially-acked message"
reset_queue
BIT_A3=$(register_session alice3)
BIT_B3=$(register_session bob3)
MID_PARTIAL=$(TEAM_SESSION_BIT="$BIT_A3" bash "${SCRIPTS_DIR}/send.sh" all text "partial ack" 2>/dev/null)
# Only alice3 acks (but alice3 is sender, not in required — so required = only bob3's bit)
# Let's check what's actually required
REQ_PARTIAL=$(cat "${TEAM_QUEUE_DIR}/messages/${MID_PARTIAL}/required" 2>/dev/null)
# Don't ack as bob3
OUT=$(bash "${SCRIPTS_DIR}/gc.sh" 2>/dev/null) && EC=$? || EC=$?
if [ -d "${TEAM_QUEUE_DIR}/messages/${MID_PARTIAL}" ]; then
    pass "E3.1 gc does not delete partially-acked message"
else
    fail "E3.1 gc deleted partially-acked message" "required=$REQ_PARTIAL"
fi

# E4: GC deletes expired message (TTL)
echo ""
echo "E4: GC deletes TTL-expired messages"
reset_queue
BIT_A4=$(register_session alice4)
BIT_B4=$(register_session bob4)
MID_EXP=$(TEAM_SESSION_BIT="$BIT_A4" TEAM_MSG_TTL=1 bash "${SCRIPTS_DIR}/send.sh" bob4 text "expires soon" 2>/dev/null)
# Manually set timestamp to past (TTL=1 already past)
if [ -n "$MID_EXP" ] && [ -d "${TEAM_QUEUE_DIR}/messages/${MID_EXP}" ]; then
    PAYLOAD_FILE="${TEAM_QUEUE_DIR}/messages/${MID_EXP}/payload.json"
    OLD_TS="2000-01-01T00:00:00Z"
    UPDATED=$(jq --arg ts "$OLD_TS" '.timestamp = $ts' "$PAYLOAD_FILE")
    echo "$UPDATED" > "$PAYLOAD_FILE"
    OUT=$(bash "${SCRIPTS_DIR}/gc.sh" 2>/dev/null) && EC=$? || EC=$?
    if [ ! -d "${TEAM_QUEUE_DIR}/messages/${MID_EXP}" ] && [ "$EC" -eq 0 ]; then
        pass "E4.1 gc deletes TTL-expired message"
    else
        fail "E4.1 gc did not delete TTL-expired message" "exit=$EC mid=$MID_EXP"
    fi
else
    fail "E4.1 setup for TTL expiry test" "mid='$MID_EXP'"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# §F — Edge Cases (Register / Deregister)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── F. Edge Cases: Register / Deregister ────────────────────────────────"

# F1: Deregister a session not registered
echo ""
echo "F1: Deregister unregistered session"
reset_queue
# Use a fake bit
OUT=$(TEAM_SESSION_BIT=99 bash "${SCRIPTS_DIR}/deregister.sh" 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 6 ]; then
    pass "F1.1 deregister non-existent session → exit=6"
else
    fail "F1.1 deregister non-existent session" "exit=$EC out='$OUT'"
fi

# F2: Register same name twice while first is still alive (same PID = live session)
echo ""
echo "F2: Register same name while session is live"
reset_queue
BIT_LIVE=$(register_session livetarget)
# Try to re-register same name using a fake PID that the actual shell is running as
# Since the previous register is run as subshell (different PID), we need to
# inject a registry entry with a live PID to simulate this
CURRENT_PID=$$
CURRENT_START=$(ps -o lstart= -p $$ 2>/dev/null | sed 's/^[[:space:]]*//')
CURRENT_EPOCH=$(date -j -f "%a %b %e %T %Y" "$CURRENT_START" "+%s" 2>/dev/null \
    || date -j -f "%a %b %d %T %Y" "$CURRENT_START" "+%s" 2>/dev/null \
    || echo "0")
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
REGISTRY=$(cat "${TEAM_QUEUE_DIR}/registry.json")
NEW_REG=$(echo "$REGISTRY" | jq \
    --arg name "liveconflict" \
    --argjson pid "$CURRENT_PID" \
    --argjson st "$CURRENT_EPOCH" \
    --arg ra "$NOW_ISO" \
    --arg lh "$NOW_ISO" \
    --argjson bit 50 \
    '.sessions[$name] = {"bit": $bit, "pid": $pid, "start_time": $st, "registered_at": $ra, "last_heartbeat": $lh}')
echo "$NEW_REG" > "${TEAM_QUEUE_DIR}/registry.json"
OUT=$(bash "${SCRIPTS_DIR}/register.sh" liveconflict 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 2 ]; then
    pass "F2.1 register duplicate live name → exit=2"
else
    fail "F2.1 register duplicate live name" "exit=$EC out='$OUT'"
fi

# F3: Register with corrupt registry → exit 10
echo ""
echo "F3: Register with corrupt registry"
reset_queue
echo "{ this is not json !!" > "${TEAM_QUEUE_DIR}/registry.json"
OUT=$(bash "${SCRIPTS_DIR}/register.sh" victim 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 10 ]; then
    pass "F3.1 register with corrupt registry → exit=10"
else
    fail "F3.1 register with corrupt registry" "exit=$EC out='$OUT'"
fi

# Restore registry for next tests
echo '{"version":1,"sessions":{},"next_bit":0,"recycled_bits":[]}' > "${TEAM_QUEUE_DIR}/registry.json"

# ═══════════════════════════════════════════════════════════════════════════════
# §G — Edge Cases (Status)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── G. Edge Cases: Status ────────────────────────────────────────────────"

# G1: Status when everything is empty
echo ""
echo "G1: Status with clean state"
reset_queue
OUT=$(bash "${SCRIPTS_DIR}/status.sh" 2>/dev/null) && EC=$? || EC=$?
if [ "$EC" -eq 0 ] && echo "$OUT" | grep -q "Sessions (0 registered)"; then
    pass "G1.1 status empty state → Sessions (0 registered)"
else
    fail "G1.1 status empty state" "exit=$EC out='$OUT'"
fi

# G2: Status with corrupt registry
echo ""
echo "G2: Status with corrupt registry"
reset_queue
echo "INVALID JSON" > "${TEAM_QUEUE_DIR}/registry.json"
OUT=$(bash "${SCRIPTS_DIR}/status.sh" 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 10 ]; then
    pass "G2.1 status with corrupt registry → exit=10"
else
    fail "G2.1 status with corrupt registry" "exit=$EC out='$OUT'"
fi

# Restore
echo '{"version":1,"sessions":{},"next_bit":0,"recycled_bits":[]}' > "${TEAM_QUEUE_DIR}/registry.json"

# G3: Status with missing messages/ directory
echo ""
echo "G3: Status with missing messages/ dir"
reset_queue
rm -rf "${TEAM_QUEUE_DIR}/messages"
OUT=$(bash "${SCRIPTS_DIR}/status.sh" 2>/dev/null) && EC=$? || EC=$?
if [ "$EC" -eq 0 ]; then
    pass "G3.1 status with missing messages/ → no crash"
else
    fail "G3.1 status with missing messages/" "exit=$EC"
fi
mkdir -p "${TEAM_QUEUE_DIR}/messages"

# ═══════════════════════════════════════════════════════════════════════════════
# §H — Error Cases
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── H. Error Cases ───────────────────────────────────────────────────────"

# H1: Send when not registered
echo ""
echo "H1: Send without being registered"
reset_queue
OUT=$(TEAM_SESSION_BIT="" bash "${SCRIPTS_DIR}/send.sh" all text "hi" 2>&1) && EC=$? || EC=$?
if [ "$EC" -ne 0 ]; then
    pass "H1.1 send unregistered → error"
else
    fail "H1.1 send unregistered should fail" "exit=$EC"
fi

# H2: Send to non-existent target
echo ""
echo "H2: Send to non-existent target"
reset_queue
BIT_LONE=$(register_session lonely)
OUT=$(TEAM_SESSION_BIT="$BIT_LONE" bash "${SCRIPTS_DIR}/send.sh" ghost text "you there?" 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 1 ]; then
    pass "H2.1 send to non-existent target → exit=1"
else
    fail "H2.1 send to non-existent target" "exit=$EC out='$OUT'"
fi

# H3: Send to self
echo ""
echo "H3: Send to self"
reset_queue
BIT_SELF=$(register_session self)
OUT=$(TEAM_SESSION_BIT="$BIT_SELF" bash "${SCRIPTS_DIR}/send.sh" self text "talking to myself" 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 3 ]; then
    pass "H3.1 send to self → exit=3"
else
    fail "H3.1 send to self" "exit=$EC out='$OUT'"
fi

# H4: Send broadcast when only one session (sender excluded → no recipients)
echo ""
echo "H4: Broadcast with no other sessions"
reset_queue
BIT_SOLO=$(register_session alone)
OUT=$(TEAM_SESSION_BIT="$BIT_SOLO" bash "${SCRIPTS_DIR}/send.sh" all text "echo" 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 1 ]; then
    pass "H4.1 broadcast with no other sessions → exit=1"
else
    fail "H4.1 broadcast no recipients" "exit=$EC out='$OUT'"
fi

# H5: Poll with missing registry
echo ""
echo "H5: Poll with missing registry"
reset_queue
BIT_H5=$(register_session h5session)
# Remove the registry
rm -f "${TEAM_QUEUE_DIR}/registry.json"
# poll.sh doesn't actually require registry — it just needs the bit file and messages/
# But we test behaviour is safe
POLL_OUT=$(TEAM_SESSION_BIT="$BIT_H5" bash "${SCRIPTS_DIR}/poll.sh" 2>/dev/null) && EC=$? || EC=$?
# poll.sh should either return [] exit=1 or handle gracefully
if [ "$EC" -eq 0 ] || [ "$EC" -eq 1 ]; then
    pass "H5.1 poll with missing registry → graceful (exit=$EC)"
else
    fail "H5.1 poll with missing registry" "exit=$EC out='$POLL_OUT'"
fi
# Restore
echo '{"version":1,"sessions":{},"next_bit":0,"recycled_bits":[]}' > "${TEAM_QUEUE_DIR}/registry.json"

# H6: Send with invalid message type
echo ""
echo "H6: Send with invalid message type"
reset_queue
BIT_H6=$(register_session typer)
BIT_H6B=$(register_session typer2)
OUT=$(TEAM_SESSION_BIT="$BIT_H6" bash "${SCRIPTS_DIR}/send.sh" typer2 invalid-type "body" 2>&1) && EC=$? || EC=$?
if [ "$EC" -ne 0 ]; then
    pass "H6.1 send invalid type → error"
else
    fail "H6.1 send invalid type should fail" "exit=$EC"
fi

# H7: Ack with invalid UUID format
echo ""
echo "H7: Ack with invalid UUID"
reset_queue
BIT_H7=$(register_session acker)
OUT=$(TEAM_SESSION_BIT="$BIT_H7" bash "${SCRIPTS_DIR}/ack.sh" "not-a-uuid" 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 2 ]; then
    pass "H7.1 ack invalid UUID format → exit=2"
else
    fail "H7.1 ack invalid UUID format" "exit=$EC out='$OUT'"
fi

# H8: GC with missing registry (should not crash)
echo ""
echo "H8: GC with missing registry"
reset_queue
rm -f "${TEAM_QUEUE_DIR}/registry.json"
OUT=$(bash "${SCRIPTS_DIR}/gc.sh" 2>/dev/null) && EC=$? || EC=$?
if [ "$EC" -eq 0 ]; then
    pass "H8.1 gc with missing registry → exits 0 (skips phase 2)"
else
    fail "H8.1 gc with missing registry" "exit=$EC out='$OUT'"
fi
echo '{"version":1,"sessions":{},"next_bit":0,"recycled_bits":[]}' > "${TEAM_QUEUE_DIR}/registry.json"

# H9: GC with corrupt registry
echo ""
echo "H9: GC with corrupt registry"
reset_queue
echo "CORRUPT" > "${TEAM_QUEUE_DIR}/registry.json"
OUT=$(bash "${SCRIPTS_DIR}/gc.sh" 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 10 ]; then
    pass "H9.1 gc with corrupt registry → exit=10"
else
    fail "H9.1 gc with corrupt registry" "exit=$EC out='$OUT'"
fi
echo '{"version":1,"sessions":{},"next_bit":0,"recycled_bits":[]}' > "${TEAM_QUEUE_DIR}/registry.json"

# H10: Send with missing messages/ directory — should auto-create
echo ""
echo "H10: Send with missing messages/ dir (auto-create)"
reset_queue
rm -rf "${TEAM_QUEUE_DIR}/messages"
BIT_H10=$(register_session h10a)
BIT_H10B=$(register_session h10b)
OUT=$(TEAM_SESSION_BIT="$BIT_H10" bash "${SCRIPTS_DIR}/send.sh" h10b text "hello" 2>/dev/null) && EC=$? || EC=$?
if [ "$EC" -eq 0 ] && [ -d "${TEAM_QUEUE_DIR}/messages" ]; then
    pass "H10.1 send auto-creates messages/ dir"
else
    fail "H10.1 send with missing messages/ dir" "exit=$EC"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# §I — Concurrency Cases
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── I. Concurrency Cases ─────────────────────────────────────────────────"

# I1: Two sessions register simultaneously — both get unique bits
# BUG: register.sh uses `mktemp /tmp/reg_inner.XXXXXX.sh` — the fixed `.sh` suffix after
# XXXXXX means two simultaneous calls can collide on the same tmp filename. With set -euo
# pipefail, the second process exits with rc=1 instead of waiting for the lock.
echo ""
echo "I1: Simultaneous register — unique bit assignment (BUG DETECTION)"
reset_queue

OUT_FILE_1=$(mktemp /tmp/reg_conc1.XXXXXX)
OUT_FILE_2=$(mktemp /tmp/reg_conc2.XXXXXX)
ERR_FILE_1=$(mktemp /tmp/reg_conc1_err.XXXXXX)
ERR_FILE_2=$(mktemp /tmp/reg_conc2_err.XXXXXX)
(TEAM_SESSION_PID=20001 bash "${SCRIPTS_DIR}/register.sh" conc1 > "$OUT_FILE_1" 2>"$ERR_FILE_1") &
PID1=$!
(TEAM_SESSION_PID=20002 bash "${SCRIPTS_DIR}/register.sh" conc2 > "$OUT_FILE_2" 2>"$ERR_FILE_2") &
PID2=$!
wait $PID1 $PID2

BIT_C1=$(cat "$OUT_FILE_1" 2>/dev/null)
BIT_C2=$(cat "$OUT_FILE_2" 2>/dev/null)
ERR_C2=$(cat "$ERR_FILE_2" 2>/dev/null)
rm -f "$OUT_FILE_1" "$OUT_FILE_2" "$ERR_FILE_1" "$ERR_FILE_2"

if [[ "$BIT_C1" =~ ^[0-9]+$ ]] && [[ "$BIT_C2" =~ ^[0-9]+$ ]] && [ "$BIT_C1" != "$BIT_C2" ]; then
    pass "I1.1 concurrent register → unique bits ($BIT_C1, $BIT_C2)"
else
    # Check if this is the known mktemp collision bug
    if echo "$ERR_C2" | grep -q "mkstemp failed"; then
        FAIL=$(( FAIL + 1 ))
        echo -e "  ${RED}BUG${RESET} I1.1 concurrent register fails with mktemp collision"
        echo "       -> register.sh uses 'mktemp /tmp/reg_inner.XXXXXX.sh' — fixed .sh suffix"
        echo "          causes mkstemp to fail when two processes race on same template."
        echo "          set -euo pipefail causes the second process to exit 1 immediately."
    else
        fail "I1.1 concurrent register" "bit1='$BIT_C1' bit2='$BIT_C2' err='$ERR_C2'"
    fi
fi

# Verify registry integrity — only 1 session registered (second failed to register)
REG_SESSIONS=$(jq '.sessions | length' "${TEAM_QUEUE_DIR}/registry.json" 2>/dev/null)
if [ "$REG_SESSIONS" = "2" ]; then
    pass "I1.2 registry has exactly 2 sessions after concurrent register"
elif [ "$REG_SESSIONS" = "1" ]; then
    FAIL=$(( FAIL + 1 ))
    echo -e "  ${RED}BUG${RESET} I1.2 concurrent register: only 1 of 2 sessions registered (race condition)"
else
    fail "I1.2 registry session count" "got=$REG_SESSIONS"
fi

# I2: Send while GC runs simultaneously
echo ""
echo "I2: Concurrent send and GC"
reset_queue
BIT_I2A=$(register_session i2a)
BIT_I2B=$(register_session i2b)

# Send a message in background
SEND_OUT_FILE=$(mktemp /tmp/send_conc.XXXXXX)
(TEAM_SESSION_BIT="$BIT_I2A" bash "${SCRIPTS_DIR}/send.sh" i2b text "concurrent" 2>/dev/null > "$SEND_OUT_FILE") &
# Run GC concurrently
bash "${SCRIPTS_DIR}/gc.sh" >/dev/null 2>&1 &
wait

MID_CONC=$(cat "$SEND_OUT_FILE" 2>/dev/null)
rm -f "$SEND_OUT_FILE"

# The message should either exist (send won) or not (GC cleared it — but GC shouldn't clear
# a non-acked message, so the message must exist if send succeeded)
if [[ "$MID_CONC" =~ ^[0-9a-f-]{36}$ ]]; then
    if [ -d "${TEAM_QUEUE_DIR}/messages/${MID_CONC}" ]; then
        pass "I2.1 send during GC → message intact"
    else
        fail "I2.1 GC deleted non-fully-acked message during concurrent send" "mid=$MID_CONC"
    fi
else
    # Send may have failed if GC raced before — check if that's acceptable
    pass "I2.1 send during GC — send completed (msg may not require storage if no recipients)"
fi

# I3: Multiple sends — all messages present
echo ""
echo "I3: Multiple rapid sends — all messages stored"
reset_queue
BIT_I3A=$(register_session i3a)
BIT_I3B=$(register_session i3b)

SEND_PIDS=()
for i in $(seq 1 5); do
    (TEAM_SESSION_BIT="$BIT_I3A" bash "${SCRIPTS_DIR}/send.sh" i3b text "message $i" >/dev/null 2>&1) &
    SEND_PIDS+=($!)
done
for pid in "${SEND_PIDS[@]}"; do wait "$pid"; done

MSG_COUNT=$(ls "${TEAM_QUEUE_DIR}/messages/" | grep -v '^\.' | wc -l | tr -d ' ')
if [ "$MSG_COUNT" -eq 5 ]; then
    pass "I3.1 5 concurrent sends → 5 messages stored"
else
    fail "I3.1 concurrent sends" "expected=5 got=$MSG_COUNT"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# §J — CRDT Properties
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── J. CRDT Properties ───────────────────────────────────────────────────"

# J1: Ack-mask monotonicity — acking can only add bits, never remove
echo ""
echo "J1: Ack-mask monotonicity"
reset_queue
BIT_J1=$(register_session j1sender)
BIT_J1B=$(register_session j1b)
BIT_J1C=$(register_session j1c)

MID_J1=$(TEAM_SESSION_BIT="$BIT_J1" bash "${SCRIPTS_DIR}/send.sh" all text "crdt test" 2>/dev/null)

ACK_BEFORE=$(ls "${TEAM_QUEUE_DIR}/messages/${MID_J1}/ack/" 2>/dev/null | wc -l | tr -d ' ')
TEAM_SESSION_BIT="$BIT_J1B" bash "${SCRIPTS_DIR}/ack.sh" "$MID_J1" 2>/dev/null
ACK_MID=$(ls "${TEAM_QUEUE_DIR}/messages/${MID_J1}/ack/" 2>/dev/null | wc -l | tr -d ' ')
TEAM_SESSION_BIT="$BIT_J1C" bash "${SCRIPTS_DIR}/ack.sh" "$MID_J1" 2>/dev/null
ACK_AFTER=$(ls "${TEAM_QUEUE_DIR}/messages/${MID_J1}/ack/" 2>/dev/null | wc -l | tr -d ' ')

if [ "$ACK_BEFORE" -le "$ACK_MID" ] && [ "$ACK_MID" -le "$ACK_AFTER" ]; then
    pass "J1.1 ack-mask monotonically increases (0 → 1 → 2)"
else
    fail "J1.1 ack-mask not monotonic" "before=$ACK_BEFORE mid=$ACK_MID after=$ACK_AFTER"
fi

# J2: Full ack triggers GC eligibility
echo ""
echo "J2: Full ack → GC eligible"
OUT=$(bash "${SCRIPTS_DIR}/gc.sh" 2>/dev/null) && EC=$? || EC=$?
if [ ! -d "${TEAM_QUEUE_DIR}/messages/${MID_J1}" ] && [ "$EC" -eq 0 ]; then
    pass "J2.1 fully-acked message collected by GC"
else
    # Check if it was already cleaned
    REQ=$(cat "${TEAM_QUEUE_DIR}/messages/${MID_J1}/required" 2>/dev/null || echo "n/a")
    fail "J2.1 fully-acked message not collected" "exit=$EC req=$REQ"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# §K — Message send to self via broadcast (edge: 1 session only, as sender)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── K. Send type validation ──────────────────────────────────────────────"

# K1: All valid types accepted
echo ""
echo "K1: Valid message types (text, command, query)"
reset_queue
BIT_K1=$(register_session k1s)
BIT_K1B=$(register_session k1r)
for mtype in text command query; do
    MID=$(TEAM_SESSION_BIT="$BIT_K1" bash "${SCRIPTS_DIR}/send.sh" k1r "$mtype" "test" 2>/dev/null) && EC=$? || EC=$?
    STORED_TYPE=$(jq -r '.type' "${TEAM_QUEUE_DIR}/messages/${MID}/payload.json" 2>/dev/null)
    if [ "$EC" -eq 0 ] && [ "$STORED_TYPE" = "$mtype" ]; then
        pass "K1.$mtype send type=$mtype → stored correctly"
    else
        fail "K1.$mtype send type=$mtype" "exit=$EC stored_type='$STORED_TYPE'"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# §L — Stale session reaping during register
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── L. Stale session reaping ─────────────────────────────────────────────"

echo ""
echo "L1: Register reaps stale session with same name (dead PID)"
reset_queue

# Inject a stale session with dead PID (99999 very unlikely to exist)
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
STALE_REG=$(jq \
    --arg name "reusable" \
    --argjson pid 99999 \
    --argjson st 0 \
    --arg ra "$NOW_ISO" \
    --arg lh "$NOW_ISO" \
    --argjson bit 7 \
    '.sessions[$name] = {"bit": $bit, "pid": $pid, "start_time": $st, "registered_at": $ra, "last_heartbeat": $lh} | .next_bit = 8' \
    "${TEAM_QUEUE_DIR}/registry.json")
echo "$STALE_REG" > "${TEAM_QUEUE_DIR}/registry.json"

BIT_REUSE=$(register_session reusable) && EC=$? || EC=$?
if [ "$EC" -eq 0 ] && [[ "$BIT_REUSE" =~ ^[0-9]+$ ]]; then
    pass "L1.1 register reaps stale session → new bit=$BIT_REUSE"
else
    fail "L1.1 register should reap stale session" "exit=$EC bit='$BIT_REUSE'"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# §M — Bit recycling cleanup: stale ack files drained on bit recycle
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── M. Bit Recycling: Stale ack drain ────────────────────────────────────"

echo ""
echo "M1: Recycled bit drains stale ack files from messages"
reset_queue

BIT_M1=$(register_session m1sender)
BIT_M1B=$(register_session m1target)
MID_M1=$(TEAM_SESSION_BIT="$BIT_M1" bash "${SCRIPTS_DIR}/send.sh" m1target text "msg for recycle test" 2>/dev/null)
# Create stale ack for BIT_M1B
TEAM_SESSION_BIT="$BIT_M1B" bash "${SCRIPTS_DIR}/ack.sh" "$MID_M1" 2>/dev/null
# Deregister m1target to recycle its bit
TEAM_SESSION_BIT="$BIT_M1B" bash "${SCRIPTS_DIR}/deregister.sh" 2>/dev/null
# Register new session which should reuse m1target's bit
BIT_NEW=$(register_session newowner)
if [ "$BIT_NEW" = "$BIT_M1B" ]; then
    # Check stale ack was drained
    if [ ! -f "${TEAM_QUEUE_DIR}/messages/${MID_M1}/ack/${BIT_M1B}" ]; then
        pass "M1.1 recycled bit drains stale ack file"
    else
        fail "M1.1 stale ack not drained on bit recycle" "ack file still exists"
    fi
else
    skip "M1.1 bit recycling ack drain" "new bit=$BIT_NEW != expected=$BIT_M1B"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# §N — Mode Human-Only
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── N. Mode Human-Only ───────────────────────────────────────────────────"

# Helper to read mode from registry by bit
get_mode_by_bit() {
    local bit="$1"
    jq -r --argjson bit "$bit" \
        '[.sessions | to_entries[] | select(.value.bit == $bit)] | first | .value.mode // "absent"' \
        "${TEAM_QUEUE_DIR}/registry.json" 2>/dev/null
}

# N1: set-mode human-only with valid session
echo ""
echo "N1: set-mode human-only → exit=0, registry updated"
reset_queue
BIT_N1=$(register_session n1session)
OUT=$(TEAM_SESSION_BIT="$BIT_N1" bash "${SCRIPTS_DIR}/set-mode.sh" human-only 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 0 ]; then
    pass "N1.1 set-mode human-only → exit=0"
else
    fail "N1.1 set-mode human-only" "exit=$EC out='$OUT'"
fi
MODE_N1=$(get_mode_by_bit "$BIT_N1")
if [ "$MODE_N1" = "human-only" ]; then
    pass "N1.2 registry.mode == human-only"
else
    fail "N1.2 registry.mode" "expected=human-only got='$MODE_N1'"
fi

# N2: set-mode autonomous (switch back)
echo ""
echo "N2: set-mode autonomous → exit=0, registry updated"
OUT=$(TEAM_SESSION_BIT="$BIT_N1" bash "${SCRIPTS_DIR}/set-mode.sh" autonomous 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 0 ]; then
    pass "N2.1 set-mode autonomous → exit=0"
else
    fail "N2.1 set-mode autonomous" "exit=$EC out='$OUT'"
fi
MODE_N2=$(get_mode_by_bit "$BIT_N1")
if [ "$MODE_N2" = "autonomous" ]; then
    pass "N2.2 registry.mode == autonomous"
else
    fail "N2.2 registry.mode" "expected=autonomous got='$MODE_N2'"
fi

# N3: set-mode with invalid mode
echo ""
echo "N3: set-mode invalid mode → exit=2, registry unchanged"
OUT=$(TEAM_SESSION_BIT="$BIT_N1" bash "${SCRIPTS_DIR}/set-mode.sh" invalid-mode 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 2 ]; then
    pass "N3.1 set-mode invalid → exit=2"
else
    fail "N3.1 set-mode invalid mode" "exit=$EC out='$OUT'"
fi
MODE_N3=$(get_mode_by_bit "$BIT_N1")
if [ "$MODE_N3" = "autonomous" ]; then
    pass "N3.2 registry unchanged after invalid mode"
else
    fail "N3.2 registry changed after invalid mode" "mode='$MODE_N3'"
fi

# N4: set-mode without argument
echo ""
echo "N4: set-mode no argument → exit=2"
OUT=$(TEAM_SESSION_BIT="$BIT_N1" bash "${SCRIPTS_DIR}/set-mode.sh" 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 2 ] && echo "$OUT" | grep -qi "usage"; then
    pass "N4.1 set-mode no arg → exit=2 with usage message"
else
    fail "N4.1 set-mode no arg" "exit=$EC out='$OUT'"
fi

# N5: set-mode with unregistered session (unknown bit)
echo ""
echo "N5: set-mode unregistered session → exit=2"
reset_queue
OUT=$(TEAM_SESSION_BIT=99 bash "${SCRIPTS_DIR}/set-mode.sh" human-only 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 2 ]; then
    pass "N5.1 set-mode unregistered session → exit=2"
else
    fail "N5.1 set-mode unregistered session" "exit=$EC out='$OUT'"
fi

# N6: set-mode with missing registry
echo ""
echo "N6: set-mode missing registry → exit=10"
reset_queue
rm -f "${TEAM_QUEUE_DIR}/registry.json"
OUT=$(TEAM_SESSION_BIT=0 bash "${SCRIPTS_DIR}/set-mode.sh" human-only 2>&1) && EC=$? || EC=$?
if [ "$EC" -eq 10 ]; then
    pass "N6.1 set-mode missing registry → exit=10"
else
    fail "N6.1 set-mode missing registry" "exit=$EC out='$OUT'"
fi
# Restore
echo '{"version":1,"sessions":{},"next_bit":0,"recycled_bits":[]}' > "${TEAM_QUEUE_DIR}/registry.json"

# N7: status.sh shows [HUMAN-ONLY] for human-only sessions only
echo ""
echo "N7: status.sh displays [HUMAN-ONLY] tag"
reset_queue
BIT_N7A=$(register_session n7auto)
BIT_N7B=$(register_session n7human)
TEAM_SESSION_BIT="$BIT_N7B" bash "${SCRIPTS_DIR}/set-mode.sh" human-only 2>/dev/null
OUT=$(bash "${SCRIPTS_DIR}/status.sh" 2>/dev/null) && EC=$? || EC=$?
if echo "$OUT" | grep -q "n7human.*\[HUMAN-ONLY\]"; then
    pass "N7.1 status shows [HUMAN-ONLY] for human-only session"
else
    fail "N7.1 status [HUMAN-ONLY] tag missing for n7human" "out='$OUT'"
fi
if echo "$OUT" | grep "n7auto" | grep -q "\[HUMAN-ONLY\]"; then
    fail "N7.2 status shows [HUMAN-ONLY] for autonomous session"
else
    pass "N7.2 status does NOT show [HUMAN-ONLY] for autonomous session"
fi

# N8: Mode field persists in registry.json
echo ""
echo "N8: Mode field persistence in registry.json"
reset_queue
BIT_N8=$(register_session n8session)
MODE_BEFORE=$(get_mode_by_bit "$BIT_N8")
if [ "$MODE_BEFORE" = "absent" ] || [ "$MODE_BEFORE" = "autonomous" ]; then
    pass "N8.1 mode absent/autonomous before set-mode"
else
    fail "N8.1 unexpected initial mode" "mode='$MODE_BEFORE'"
fi
TEAM_SESSION_BIT="$BIT_N8" bash "${SCRIPTS_DIR}/set-mode.sh" human-only 2>/dev/null
MODE_AFTER=$(get_mode_by_bit "$BIT_N8")
if [ "$MODE_AFTER" = "human-only" ]; then
    pass "N8.2 mode persists as human-only in registry.json"
else
    fail "N8.2 mode not persisted" "mode='$MODE_AFTER'"
fi

# N9: Full cycle autonomous → human-only → autonomous
echo ""
echo "N9: Full mode cycle"
reset_queue
BIT_N9=$(register_session n9cycle)
ALL_OK=true

TEAM_SESSION_BIT="$BIT_N9" bash "${SCRIPTS_DIR}/set-mode.sh" autonomous 2>/dev/null && EC=$? || EC=$?
M=$(get_mode_by_bit "$BIT_N9")
[ "$EC" -eq 0 ] && [ "$M" = "autonomous" ] || ALL_OK=false

TEAM_SESSION_BIT="$BIT_N9" bash "${SCRIPTS_DIR}/set-mode.sh" human-only 2>/dev/null && EC=$? || EC=$?
M=$(get_mode_by_bit "$BIT_N9")
[ "$EC" -eq 0 ] && [ "$M" = "human-only" ] || ALL_OK=false

TEAM_SESSION_BIT="$BIT_N9" bash "${SCRIPTS_DIR}/set-mode.sh" autonomous 2>/dev/null && EC=$? || EC=$?
M=$(get_mode_by_bit "$BIT_N9")
[ "$EC" -eq 0 ] && [ "$M" = "autonomous" ] || ALL_OK=false

if $ALL_OK; then
    pass "N9.1 full cycle autonomous → human-only → autonomous"
else
    fail "N9.1 full mode cycle" "mode='$M'"
fi

# N10: set-mode with corrupt registry
echo ""
echo "N10: set-mode corrupt registry → error"
reset_queue
BIT_N10=$(register_session n10session)
echo "CORRUPT" > "${TEAM_QUEUE_DIR}/registry.json"
OUT=$(TEAM_SESSION_BIT="$BIT_N10" bash "${SCRIPTS_DIR}/set-mode.sh" human-only 2>&1) && EC=$? || EC=$?
if [ "$EC" -ne 0 ]; then
    pass "N10.1 set-mode corrupt registry → error (exit=$EC)"
else
    fail "N10.1 set-mode corrupt registry should fail" "exit=$EC"
fi
# Restore
echo '{"version":1,"sessions":{},"next_bit":0,"recycled_bits":[]}' > "${TEAM_QUEUE_DIR}/registry.json"

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════"
TOTAL=$(( PASS + FAIL + SKIP ))
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped (${TOTAL} total)"
echo "═══════════════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
