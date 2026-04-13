#!/usr/bin/env bash
set -uo pipefail

# go-cycle.sh <bit> <scripts-dir>
# Blocking wait pour le Grand Orchestrateur.
# Attend 5 minutes (sous le idle timeout de 300s), puis retourne le status.
# Le GO DOIT relancer ce script apres chaque cycle d'actions.
# Exit codes: 0=cycle termine (status JSON on stdout), 10=not registered

if [ $# -lt 2 ]; then
    echo "Usage: $0 <bit> <scripts-dir>" >&2
    exit 2
fi

BIT="$1"
SCRIPTS_DIR="$2"
TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"

WAIT=240  # 4 min — sous le idle timeout de 300s

# Poll messages + heartbeat pendant l'attente
POLL_INTERVAL=10   # poll toutes les 10s (GO doit etre reactif)
elapsed=0
while [ "$elapsed" -lt "$WAIT" ]; do
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))

    # Heartbeat
    . "$SCRIPTS_DIR/_common.sh" 2>/dev/null || true
    touch "$TEAM_QUEUE_DIR/.sessions/${SESSION_PID:-$$}.heartbeat" 2>/dev/null || true

    # Poll messages — si un message arrive, retourner immediatement
    MSGS=$(TEAM_SESSION_BIT="$BIT" bash "$SCRIPTS_DIR/check-messages.sh" 2>/dev/null) || true
    if [ -n "$MSGS" ] && [ "$MSGS" != "null" ] && [ "$MSGS" != "[]" ]; then
        # Message(s) recu(s) — retourner le status + les messages pour que le GO agisse
        echo "$MSGS"
        echo "---"
        bash "$SCRIPTS_DIR/status.sh" 2>/dev/null
        exit 0
    fi
done

# GC avant le scan
TEAM_SESSION_BIT="$BIT" bash "$SCRIPTS_DIR/gc.sh" 2>/dev/null || true

# Retourner le status pour que le GO agisse
bash "$SCRIPTS_DIR/status.sh" 2>/dev/null
exit 0
