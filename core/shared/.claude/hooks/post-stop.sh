#!/bin/bash
# post-stop.sh
# Fires when the agent stops (Stop event). Copies this checkout's sessions into the shared
# store (most session writes go through the shell, so no write hook sees them), and in
# interactive mode reminds the user that implementation waits for approval.

SCRIPTS="$(cd "$(dirname "$0")" && pwd)/../scripts"  # this hook's own version, not the checkout's
PY=$(command -v python3 2>/dev/null)
"${PY:-false}" -c "" 2>/dev/null || PY=$(command -v python 2>/dev/null)
"${PY:-false}" -c "" 2>/dev/null || exit 0

cat >/dev/null 2>&1
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 0
[ -f .claude/scripts/plan-integrity.py ] || [ -f .claude/scripts/cg_session.py ] || exit 0  # not a codegate checkout

"$PY" "$SCRIPTS"/cg_session.py sync >/dev/null 2>&1
REL_DIR=$("$PY" "$SCRIPTS"/cg_session.py dir 2>/dev/null)
[ -z "$REL_DIR" ] && exit 0

STATE=$(cat "$REL_DIR/state" 2>/dev/null | tr -d '[:space:]')
MODE=$(cat "$REL_DIR/mode" 2>/dev/null | tr -d '[:space:]')

if [ "$STATE" = "IMPLEMENTING" ] && [ "${MODE:-interactive}" = "interactive" ]; then
  echo ""
  echo "IMPLEMENTATION AWAITING APPROVAL — $(head -1 "$REL_DIR/task.md" 2>/dev/null)"
  echo "When it is complete, type /cg-approve implementation to run the quality gate."
  echo ""
fi

exit 0
