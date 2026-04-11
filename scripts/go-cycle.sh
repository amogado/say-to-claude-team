#!/usr/bin/env bash
set -uo pipefail

# go-cycle.sh <bit> <scripts-dir>
# Blocking wait pour le Grand Orchestrateur.
# Poll les messages toutes les 10s. Retourne DES qu'un message arrive ou timeout 4min.
# Le GO DOIT relancer ce script apres chaque cycle d'actions.
# Exit codes: 0=messages found (JSON on stdout), 1=timeout (status on stdout), 10=not registered

if [ $# -lt 2 ]; then
    echo "Usage: $0 <bit> <scripts-dir>" >&2
    exit 2
fi

BIT="$1"
SCRIPTS_DIR="$2"
TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"

INTERVAL=10
TIMEOUT=240  # 4 min — sous le idle timeout de 300s
GC_INTERVAL=120

elapsed=0
gc_elapsed=0

while [ "$elapsed" -lt "$TIMEOUT" ]; do
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
    gc_elapsed=$((gc_elapsed + INTERVAL))

    # Heartbeat
    . "$SCRIPTS_DIR/_common.sh" 2>/dev/null || true
    touch "$TEAM_QUEUE_DIR/.sessions/${SESSION_PID:-$$}.heartbeat" 2>/dev/null || true

    # GC periodique
    if [ "$gc_elapsed" -ge "$GC_INTERVAL" ]; then
        TEAM_SESSION_BIT="$BIT" bash "$SCRIPTS_DIR/gc.sh" >/dev/null 2>&1 || true
        gc_elapsed=0
    fi

    # Poll pour messages — retourne immediatement si message trouve
    result=""
    result=$(TEAM_SESSION_BIT="$BIT" bash "$SCRIPTS_DIR/poll.sh" 2>/dev/null)
    rc=$?

    case "$rc" in
        0)
            if [ -n "$result" ] && [ "$result" != "[]" ]; then
                echo "$result"
                exit 0
            fi
            ;;
        10)
            echo "NOT_REGISTERED" >&2
            exit 10
            ;;
    esac
done

# Timeout — retourner le status pour que le GO agisse quand meme
bash "$SCRIPTS_DIR/status.sh" 2>/dev/null
exit 1
