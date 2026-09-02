#!/bin/bash
# Dumps the running WM's live state to its stderr.
#
# `pkill -x` matches the executable name exactly. Plain `pkill -f wispos` also
# matches the shell that launched it, and a shell's default SIGUSR1 action is to
# die — which kills the terminal, not the WM.
set -euo pipefail
pkill -USR1 -x wispos && echo "state dumped to wispos's stderr"
