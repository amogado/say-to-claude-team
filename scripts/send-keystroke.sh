#!/usr/bin/env bash
set -uo pipefail

# send-keystroke.sh <window-index> <text>
# Envoie des frappes clavier dans une fenetre Terminal spécifique.
# Utile pour le grand-orchestrateur qui doit interagir avec les sessions.
# Exit codes: 0=ok, 1=erreur, 2=usage

if [ $# -lt 2 ]; then
    echo "Usage: $0 <window-index|all-claude> <text>" >&2
    echo "  window-index: numero de la fenetre Terminal (1-based)" >&2
    echo "  all-claude: envoie a toutes les fenetres claude" >&2
    echo "  text: texte a taper (Enter est ajoute automatiquement)" >&2
    exit 2
fi

TARGET="$1"
shift
TEXT="$*"

if [ "$TARGET" = "all-claude" ]; then
    # Trouver toutes les fenetres Terminal qui contiennent "claude"
    osascript -e "
        tell application \"Terminal\"
            set winCount to count of windows
            set sentCount to 0
            repeat with i from 1 to winCount
                try
                    set winName to name of window i
                    if winName contains \"claude\" then
                        set index of window i to 1
                        activate
                        delay 0.3
                        tell application \"System Events\"
                            tell process \"Terminal\"
                                keystroke \"$TEXT\"
                                delay 0.2
                                keystroke return
                            end tell
                        end tell
                        set sentCount to sentCount + 1
                        delay 0.5
                    end if
                end try
            end repeat
            return \"Sent to \" & sentCount & \" claude windows\"
        end tell
    " 2>&1
elif [ "$TARGET" = "list" ]; then
    # Lister les fenetres Terminal
    osascript -e "
        tell application \"Terminal\"
            set winCount to count of windows
            set results to \"\"
            repeat with i from 1 to winCount
                try
                    set results to results & i & \": \" & name of window i & linefeed
                on error
                    set results to results & i & \": (unnamed)\" & linefeed
                end try
            end repeat
            return results
        end tell
    " 2>&1
else
    # Envoyer a une fenetre specifique
    WIN_INDEX="$TARGET"
    osascript -e "
        tell application \"Terminal\"
            set index of window $WIN_INDEX to 1
            activate
            delay 0.3
            tell application \"System Events\"
                tell process \"Terminal\"
                    keystroke \"$TEXT\"
                    delay 0.2
                    keystroke return
                end tell
            end tell
            return \"Sent to window $WIN_INDEX\"
        end tell
    " 2>&1
fi
