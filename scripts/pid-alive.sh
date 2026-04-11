#!/usr/bin/env bash
set -uo pipefail

# pid-alive.sh <PID>
# Check if a PID is alive. Exit 0 = alive, exit 1 = dead.

if [ $# -lt 1 ]; then
    echo "Usage: $0 <PID>" >&2
    exit 2
fi

kill -0 "$1" 2>/dev/null
