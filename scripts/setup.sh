#!/usr/bin/env bash
set -euo pipefail

# setup.sh — One-shot installer for say-to-claude-team message queue
# Creates ~/.claude/team-queue/ and configures the hook entry point.

TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"
SKILL_DIR="$HOME/.claude/skills/say-to-claude-team"
SCRIPTS_DIR="$SKILL_DIR/scripts"

echo "=== say-to-claude-team setup ==="
echo ""

# ── Check dependencies ──────────────────────────────────────────────────────

MISSING_DEPS=()

check_dep() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        MISSING_DEPS+=("$cmd")
        echo "  [MISSING] $cmd"
    else
        echo "  [OK]      $cmd ($(command -v "$cmd"))"
    fi
}

echo "Checking dependencies..."
check_dep jq
check_dep uuidgen
check_dep lockf

if [[ "${#MISSING_DEPS[@]}" -gt 0 ]]; then
    echo ""
    echo "WARNING: Missing dependencies: ${MISSING_DEPS[*]}"
    echo "  Install with: brew install ${MISSING_DEPS[*]}"
    echo "  Note: lockf is part of FreeBSD libc — on macOS it's in /usr/bin/lockf (built-in)"
    echo ""
    # lockf is built-in on macOS — only warn, don't abort
    NON_BUILTIN_MISSING=()
    for dep in "${MISSING_DEPS[@]}"; do
        [[ "$dep" == "lockf" ]] && continue
        NON_BUILTIN_MISSING+=("$dep")
    done
    if [[ "${#NON_BUILTIN_MISSING[@]}" -gt 0 ]]; then
        echo "ERROR: Critical dependencies missing: ${NON_BUILTIN_MISSING[*]}"
        echo "Please install them before continuing."
        exit 1
    fi
else
    echo "  All dependencies satisfied."
fi
echo ""

# ── Create directory structure ───────────────────────────────────────────────

echo "Creating queue directory structure at: $TEAM_QUEUE_DIR"

mkdir -p "$TEAM_QUEUE_DIR/messages"
mkdir -p "$TEAM_QUEUE_DIR/.sessions"

# Restrict permissions to owner only (mitigates information leakage and impersonation)
chmod 700 "$TEAM_QUEUE_DIR"
chmod 700 "$TEAM_QUEUE_DIR/messages"
chmod 700 "$TEAM_QUEUE_DIR/.sessions"

echo "  [OK] $TEAM_QUEUE_DIR/messages/ (mode 700)"
echo "  [OK] $TEAM_QUEUE_DIR/.sessions/ (mode 700)"
echo "  Scripts: $SCRIPTS_DIR (via skill install)"

# ── Initialize registry.json ─────────────────────────────────────────────────

REGISTRY="$TEAM_QUEUE_DIR/registry.json"
if [[ ! -f "$REGISTRY" ]]; then
    cat > "$REGISTRY" <<'EOF'
{"version":1,"sessions":{},"next_bit":0,"recycled_bits":[]}
EOF
    chmod 600 "$REGISTRY"
    echo "  [OK] registry.json initialized (mode 600)"
else
    echo "  [SKIP] registry.json already exists — not overwritten"
fi

# ── Create registry.lock ─────────────────────────────────────────────────────

LOCK_FILE="$TEAM_QUEUE_DIR/registry.lock"
if [[ ! -f "$LOCK_FILE" ]]; then
    touch "$LOCK_FILE"
    echo "  [OK] registry.lock created"
else
    echo "  [SKIP] registry.lock already exists"
fi

# ── Verify skill is installed ────────────────────────────────────────────────

echo ""
if [[ -d "$SCRIPTS_DIR" ]]; then
    echo "  [OK] Skill installed at $SKILL_DIR"
else
    echo "  [ERROR] Skill not found at $SKILL_DIR"
    echo "  Run: skill install say-to-claude-team"
    exit 1
fi

# ── Configure SessionStart hook in settings.json ────────────────────────────

SETTINGS="$HOME/.claude/settings.json"
echo ""
echo "Configuring hooks..."

if [[ -f "$SETTINGS" ]]; then
    # Check if SessionStart hook already exists
    if jq -e '.hooks.SessionStart' "$SETTINGS" &>/dev/null; then
        echo "  [SKIP] SessionStart hook already configured"
    else
        # Add SessionStart hook, merging with existing hooks
        TMP_SETTINGS=$(mktemp "${TMPDIR:-/tmp}/settings_$$.XXXXXX")
        jq '.hooks = (.hooks // {}) + {
          "SessionStart": [
            {
              "matcher": "",
              "hooks": [
                {
                  "type": "command",
                  "command": "bash $HOME/.claude/skills/say-to-claude-team/scripts/register.sh \"$(hostname -s)-$$\" 2>/dev/null; true"
                }
              ]
            }
          ]
        }' "$SETTINGS" > "$TMP_SETTINGS" && mv "$TMP_SETTINGS" "$SETTINGS"
        echo "  [OK] SessionStart hook added (auto-register at session start)"
    fi
else
    echo "  [WARN] $SETTINGS not found — hook not configured"
fi

# ── Configure permissions ───────────────────────────────────────────────────

echo ""
echo "Configuring permissions..."

# Add bash permissions for all say-to-claude-team scripts
if [[ -f "$SETTINGS" ]]; then
    if jq -e '.permissions.allow' "$SETTINGS" | grep -q "say-to-claude-team" 2>/dev/null; then
        echo "  [SKIP] Bash permissions already configured"
    else
        TMP_SETTINGS=$(mktemp "${TMPDIR:-/tmp}/settings_$$.XXXXXX")
        jq --arg home "$HOME" '.permissions.allow = ((.permissions.allow // []) + [
           "Bash(bash ~/.claude/skills/say-to-claude-team/scripts/*)",
           ("Bash(bash " + $home + "/.claude/skills/say-to-claude-team/scripts/*)"),
           ("Bash(bash " + $home + "/.claude/skills/say-to-claude-team/scripts/whoami.sh*)"),
           ("Bash(bash " + $home + "/.claude/skills/say-to-claude-team/scripts/register.sh*)"),
           ("Bash(bash " + $home + "/.claude/skills/say-to-claude-team/scripts/status.sh*)"),
           ("Bash(bash " + $home + "/.claude/skills/say-to-claude-team/scripts/poll.sh*)"),
           ("Bash(bash " + $home + "/.claude/skills/say-to-claude-team/scripts/send.sh*)"),
           ("Bash(bash " + $home + "/.claude/skills/say-to-claude-team/scripts/ack.sh*)"),
           ("Bash(bash " + $home + "/.claude/skills/say-to-claude-team/scripts/gc.sh*)"),
           ("Bash(bash " + $home + "/.claude/skills/say-to-claude-team/scripts/deregister.sh*)"),
           ("Bash(bash " + $home + "/.claude/skills/say-to-claude-team/scripts/rename.sh*)"),
           ("Bash(bash " + $home + "/.claude/skills/say-to-claude-team/scripts/watch-and-wait.sh*)"),
           ("Bash(bash " + $home + "/.claude/skills/say-to-claude-team/scripts/setup.sh*)"),
           ("Bash(bash " + $home + "/.claude/skills/say-to-claude-team/scripts/heartbeat.sh*)"),
           "Bash(TEAM_SESSION_BIT=*)",
           "Read(~/.claude/skills/say-to-claude-team/**)",
           ("Read(" + $home + "/.claude/skills/say-to-claude-team/**)")
        ] | unique)' "$SETTINGS" > "$TMP_SETTINGS" && mv "$TMP_SETTINGS" "$SETTINGS"
        echo "  [OK] Bash permissions added for say-to-claude-team scripts"
    fi
fi

# ── Configure statusline ────────────────────────────────────────────────────

STATUSLINE="$HOME/.claude/statusline-command.sh"
echo ""
echo "Configuring statusline..."

TQ_SOURCE_LINE=". \"$SKILL_DIR/scripts/statusline-team-queue.sh\""
TQ_STATUS_LINE='if [ -n "$team_queue" ]; then status+=" | $team_queue"; fi'

if [[ -f "$STATUSLINE" ]]; then
    if grep -q "statusline-team-queue.sh" "$STATUSLINE" 2>/dev/null; then
        echo "  [SKIP] Statusline already sources team-queue"
    else
        # Inject source line before "# Build status line" and display line after status=
        TMP_SL=$(mktemp "${TMPDIR:-/tmp}/statusline_$$.XXXXXX")
        awk -v src="$TQ_SOURCE_LINE" -v disp="$TQ_STATUS_LINE" '
            /# Build status line/ {
                print src
                print ""
            }
            { print }
            /^status="\$model"/ {
                print ""
                print "# Add Team Queue status"
                print disp
            }
        ' "$STATUSLINE" > "$TMP_SL" && mv "$TMP_SL" "$STATUSLINE" && chmod +x "$STATUSLINE"
        echo "  [OK] Statusline updated (sources statusline-team-queue.sh)"
    fi
else
    echo "  [SKIP] No statusline-command.sh found"
fi

# ── Configure shell function (auto-connect at session start) ───────────────

SHELL_RC="$HOME/.zshrc"
[[ ! -f "$SHELL_RC" ]] && SHELL_RC="$HOME/.bashrc"

TQ_MARKER="# say-to-claude-team: auto-connect function"

echo ""
echo "Configuring shell function..."

if [[ -f "$SHELL_RC" ]]; then
    if grep -q "say-to-claude-team.*auto-connect" "$SHELL_RC" 2>/dev/null; then
        echo "  [SKIP] Shell function already configured in $SHELL_RC"
    else
        cat >> "$SHELL_RC" << 'SHELL_FUNC'

# say-to-claude-team: auto-connect function
# When 'claude' is launched without arguments in an interactive terminal,
# auto-connect to the team queue. All other usages pass through normally.
# Bypass with: CLAUDE_NO_TEAM=1 claude
claude() {
  if [ $# -eq 0 ] && [ -t 0 ] && [ -z "${CLAUDE_NO_TEAM:-}" ]; then
    command claude "/say-to-claude-team connect"
  else
    command claude "$@"
  fi
}
SHELL_FUNC
        echo "  [OK] Added claude() function to $SHELL_RC"
        echo "  Run 'source $SHELL_RC' or restart your terminal to activate"
    fi
else
    echo "  [WARN] No .zshrc or .bashrc found — function not configured"
fi

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "=== Setup Complete ==="
echo ""
echo "  Queue:   $TEAM_QUEUE_DIR"
echo "  Scripts: $SCRIPTS_DIR"
echo ""
echo "  Hook SessionStart: auto-register chaque session au demarrage"
echo "  Shell alias: claude lance automatiquement /say-to-claude-team connect"
echo "  Statusline: affiche session name, bit, messages, heartbeat"
echo "  Watcher: se lance automatiquement via connect"
echo ""
echo "Commandes: /say-to-claude-team [setup | send | check | status | watch | gc]"
