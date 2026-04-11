#!/usr/bin/env bash
set -uo pipefail

# sessions-info.sh
# Affiche toutes les fiches de session en une seule sortie.
# Usage: bash sessions-info.sh

TEAM_QUEUE_DIR="${TEAM_QUEUE_DIR:-$HOME/.claude/team-queue}"
INFO_DIR="${TEAM_QUEUE_DIR}/sessions-info"

if [ ! -d "$INFO_DIR" ]; then
    echo "Pas de fiches de session."
    exit 0
fi

shopt -s nullglob
files=("$INFO_DIR"/*.md)
shopt -u nullglob

if [ ${#files[@]} -eq 0 ]; then
    echo "Pas de fiches de session."
    exit 0
fi

for f in "${files[@]}"; do
    echo "=== $(basename "$f" .md) ==="
    cat "$f"
    echo ""
done
