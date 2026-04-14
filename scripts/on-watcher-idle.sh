#!/bin/bash
# TeammateIdle hook — keeps queue-watcher alive by preventing idle
# Configured globally in ~/.claude/settings.json
# Exit 2 + stderr = teammate receives feedback and stays active
# Exit 0 = teammate goes idle normally

INPUT=$(cat)
TEAMMATE=$(echo "$INPUT" | jq -r '.teammate_name // empty')

if [[ "$TEAMMATE" == "queue-watcher" ]]; then
  echo "Relance ta boucle watch-and-wait.sh. Ne t'arrete pas." >&2
  exit 2
fi

exit 0
