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

# Heartbeat pendant l'attente (toutes les 30s)
elapsed=0
while [ "$elapsed" -lt "$WAIT" ]; do
    sleep 30
    elapsed=$((elapsed + 30))

    # Heartbeat
    . "$SCRIPTS_DIR/_common.sh" 2>/dev/null || true
    touch "$TEAM_QUEUE_DIR/.sessions/${SESSION_PID:-$$}.heartbeat" 2>/dev/null || true
done

# GC avant le scan
TEAM_SESSION_BIT="$BIT" bash "$SCRIPTS_DIR/gc.sh" 2>/dev/null || true

# Retourner le status pour que le GO agisse
bash "$SCRIPTS_DIR/status.sh" 2>/dev/null
exit 0
