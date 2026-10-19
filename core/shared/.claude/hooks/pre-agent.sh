#!/bin/bash
# pre-agent.sh
# Fires before a sub-agent is dispatched (PreToolUse on Task|Agent).
# Elicitation and planning belong to a task: dispatching them on a branch with no task, or
# for a task whose PR/MR already exists, means a new task was started without Phase 0 — the
# work would land on the wrong branch.

SCRIPTS="$(cd "$(dirname "$0")" && pwd)/../scripts"  # this hook's own version, not the checkout's
PY=$(command -v python3 2>/dev/null)
"${PY:-false}" -c "" 2>/dev/null || PY=$(command -v python 2>/dev/null)
"${PY:-false}" -c "" 2>/dev/null || exit 0

INPUT=$(cat)
PROMPT=$("$PY" -c "
import json, sys
try:
    d = json.load(sys.stdin)
    t = d.get('tool_input', {})
    print(t.get('prompt', ''))
except Exception:
    print('')
" <<< "$INPUT" 2>/dev/null)

case "$PROMPT" in
  *agents/elicitation/prompt.md*|*agents/planning/prompt.md*) ;;
  *) exit 0 ;;
esac

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$ROOT" || exit 0
[ -f .claude/scripts/plan-integrity.py ] || [ -f .claude/scripts/cg_session.py ] || exit 0  # not a codegate checkout

REL_DIR=$("$PY" "$SCRIPTS"/cg_session.py dir 2>/dev/null)
BRANCH=$(git branch --show-current 2>/dev/null)
if [ -z "$REL_DIR" ]; then
  echo "No task on branch '$BRANCH': elicitation and planning run inside a task. Start it first (skill cg-phase-0, then cg-phase-1 opens the session)." >&2
  exit 2
fi

STATE=$(cat "$REL_DIR/state" 2>/dev/null | tr -d '[:space:]')
case "$STATE" in
  PR_CREATED|PR_UPDATED|MERGED|ABANDONED)
    echo "The task on '$BRANCH' is past its PR/MR ($STATE). New work is a new task with its own branch (skill cg-phase-0); a scoped extension of this PR/MR is rework (skill cg-rework)." >&2
    exit 2
    ;;
esac
exit 0
