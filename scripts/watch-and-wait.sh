#!/usr/bin/env bash
set -uo pipefail

# watch-and-wait.sh <bit> <scripts-dir>
# Blocking poll: boucle interne bash, ne retourne que quand un message arrive ou timeout.
# GC automatique toutes les 5 minutes.
# Exit codes: 0=messages found (JSON on stdout), 1=timeout, 10=not registered

if [ $# -lt 2 ]; then
    echo "Usage: $0 <bit> <scripts-dir>" >&2
    exit 2
fi

BIT="$1"
SCRIPTS_DIR="$2"

INTERVAL=10        # secondes entre chaque poll
TIMEOUT=240        # 4 min — sous le idle timeout de 300s de SessionIdleManager
GC_INTERVAL=300    # GC toutes les 5 minutes

elapsed=0
gc_elapsed=0

# GC initial au démarrage
TEAM_SESSION_BIT="$BIT" bash "$SCRIPTS_DIR/gc.sh" 2>/dev/null || true

while [ "$elapsed" -lt "$TIMEOUT" ]; do
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
    gc_elapsed=$((gc_elapsed + INTERVAL))

    # GC toutes les 5 minutes
    if [ "$gc_elapsed" -ge "$GC_INTERVAL" ]; then
        TEAM_SESSION_BIT="$BIT" bash "$SCRIPTS_DIR/gc.sh" 2>/dev/null || true
        gc_elapsed=0
    fi

    # Poll
    result=""
    result=$(TEAM_SESSION_BIT="$BIT" bash "$SCRIPTS_DIR/poll.sh" 2>/dev/null)
    rc=$?

    case "$rc" in
        0)
            # Messages trouvés
            if [ -n "$result" ] && [ "$result" != "[]" ]; then
                echo "$result"
                exit 0
            fi
            ;;
        10)
            # Pas enregistré
            echo "NOT_REGISTERED" >&2
            exit 10
            ;;
        *)
            # 1 = vide, autre = erreur — on continue
            ;;
    esac
done

# Timeout sans message
exit 1
