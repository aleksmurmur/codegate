#!/bin/bash
# post-stop.sh
# Fires when the agent stops (Stop event). Copies this checkout's sessions into the shared
# store: most session writes go through the shell, so no write hook sees them.

SCRIPTS="$(cd "$(dirname "$0")" && pwd)/../scripts"  # this hook's own version, not the checkout's
PY=$(command -v python3 2>/dev/null)
"${PY:-false}" -c "" 2>/dev/null || PY=$(command -v python 2>/dev/null)
"${PY:-false}" -c "" 2>/dev/null || exit 0

cat >/dev/null 2>&1
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 0
[ -f .claude/scripts/plan-integrity.py ] || [ -f .claude/scripts/cg_session.py ] || exit 0  # not a codegate checkout

"$PY" "$SCRIPTS"/cg_session.py sync >/dev/null 2>&1
exit 0
