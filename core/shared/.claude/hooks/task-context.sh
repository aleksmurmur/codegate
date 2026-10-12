#!/bin/bash
# task-context.sh
# Fires on every user message (UserPromptSubmit); stdout reaches the model as context.
# One line: which task this checkout holds and in what state, so the agent can tell whether
# the message continues it, concerns its open MR, or is another task. It also records which
# chat works in this folder, and warns when another chat did so recently.

PY=$(command -v python3 2>/dev/null)
"${PY:-false}" -c "" 2>/dev/null || PY=$(command -v python 2>/dev/null)
"${PY:-false}" -c "" 2>/dev/null || exit 0

INPUT=$(cat)
FIELDS=$("$PY" -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get('session_id') or '-')
print(d.get('cwd') or '-')
" <<< "$INPUT" 2>/dev/null)
CHAT=$(printf '%s\n' "$FIELDS" | sed -n 1p)
CWD=$(printf '%s\n' "$FIELDS" | sed -n 2p)
[ -n "$CWD" ] && [ "$CWD" != "-" ] && cd "$CWD" 2>/dev/null
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$ROOT" || exit 0
[ -f .claude/scripts/cg_session.py ] || exit 0

"$PY" .claude/scripts/cg_session.py sync >/dev/null 2>&1
BRANCH=$(git branch --show-current 2>/dev/null)
REL_DIR=$("$PY" .claude/scripts/cg_session.py dir 2>/dev/null)

if [ -n "$REL_DIR" ]; then
  STATE=$(cat "$REL_DIR/state" 2>/dev/null | tr -d '[:space:]')
  MODE=$(cat "$REL_DIR/mode" 2>/dev/null | tr -d '[:space:]')
  TICKET=$(cat "$REL_DIR/ticket" 2>/dev/null | tr -d '[:space:]')
  NAME=${TICKET:-$(basename "$REL_DIR")}
  case "$STATE" in
    MERGED|ABANDONED)
      LINE="codegate: task $NAME on '$BRANCH' is closed ($STATE). Code changes need a new task (skill cg-phase-0)." ;;
    PR_CREATED|PR_UPDATED|REWORK)
      LINE="codegate: task $NAME on '$BRANCH', state $STATE (MR open). A fix to that MR is rework (skill cg-rework); other work is a new task (skill cg-phase-0)." ;;
    *)
      LINE="codegate: task $NAME on '$BRANCH', state ${STATE:-IDLE}, mode ${MODE:-interactive}. Other work is a new task (skill cg-phase-0)." ;;
  esac
else
  LINE="codegate: no task on '${BRANCH:-detached HEAD}'. Code changes start with a task (skill cg-phase-0)."
fi

if [ -n "$CHAT" ] && [ "$CHAT" != "-" ]; then
  OTHER=$("$PY" .claude/scripts/cg_session.py claim --chat "$CHAT" 2>/dev/null)
  case "$OTHER" in
    *minutes_ago*)
      MIN=$(printf '%s' "$OTHER" | sed -E 's/.*"minutes_ago": ?([0-9]+).*/\1/')
      LINE="$LINE Another chat worked in this folder $MIN min ago: if it is still busy (ListAgents), start new tasks in a new worktree." ;;
  esac
fi

echo "$LINE"
exit 0
