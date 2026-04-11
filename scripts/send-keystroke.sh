#!/usr/bin/env bash
set -uo pipefail

# send-keystroke.sh <window-index|list|all-claude> <text>
# Envoie des frappes clavier dans une fenetre Terminal spécifique.
# Exit codes: 0=ok, 1=erreur, 2=usage

if [ $# -lt 1 ]; then
    echo "Usage: $0 list" >&2
    echo "       $0 <window-index> <text>" >&2
    echo "       $0 all-claude <text>" >&2
    exit 2
fi

TARGET="$1"
shift

# Escape text for safe AppleScript embedding
escape_for_applescript() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

if [ "$TARGET" = "list" ]; then
    osascript -e '
        tell application "Terminal"
            set winCount to count of windows
            set results to ""
            repeat with i from 1 to winCount
                try
                    set results to results & i & ": " & name of window i & linefeed
                on error
                    set results to results & i & ": (unnamed)" & linefeed
                end try
            end repeat
            return results
        end tell
    ' 2>&1
    exit $?
fi

# From here, we need text
if [ $# -lt 1 ]; then
    echo "Usage: $0 $TARGET <text>" >&2
    exit 2
fi

TEXT="$*"
SAFE_TEXT=$(escape_for_applescript "$TEXT")

if [ "$TARGET" = "all-claude" ]; then
    osascript -e "
        tell application \"Terminal\"
            set winCount to count of windows
            set sentCount to 0
            repeat with i from 1 to winCount
                try
                    set winName to name of window i
                    if winName contains \"claude\" then
                        set frontmost of window i to true
                        activate
                        delay 0.3
                        tell application \"System Events\"
                            tell process \"Terminal\"
                                keystroke \"$SAFE_TEXT\"
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
else
    # Validate window index is numeric
    if ! [[ "$TARGET" =~ ^[0-9]+$ ]]; then
        echo "Error: window index must be a number, got '$TARGET'" >&2
        exit 2
    fi
    WIN_INDEX="$TARGET"
    osascript -e "
        tell application \"Terminal\"
            set frontmost of window $WIN_INDEX to true
            activate
            delay 0.3
            tell application \"System Events\"
                tell process \"Terminal\"
                    keystroke \"$SAFE_TEXT\"
                    delay 0.2
                    keystroke return
                end tell
            end tell
            return \"Sent to window $WIN_INDEX\"
        end tell
    " 2>&1
fi
