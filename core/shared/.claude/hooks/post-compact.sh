#!/bin/bash
# post-compact.sh
# Fires on every SessionStart (startup, resume, /clear, compaction). Finds the task of this
# checkout — the session bound to the branch checked out here — and tells the agent where
# it stands and which phase skill to load.
#
# Silent when there is no task on this branch, or the task is closed.

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
print(d.get('cwd') or '')
print(d.get('session_id') or '')
print(d.get('source') or '')
" <<< "$INPUT" 2>/dev/null)
CWD=$(printf '%s\n' "$FIELDS" | sed -n 1p)
CHAT=$(printf '%s\n' "$FIELDS" | sed -n 2p)
SOURCE=$(printf '%s\n' "$FIELDS" | sed -n 3p)
[ -z "$CWD" ] && CWD="$(pwd)"
cd "$CWD" 2>/dev/null || exit 0
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 0

"$PY" .claude/scripts/cg_session.py sync >/dev/null 2>&1
# /clear and compaction continue the same conversation under a new id: take the folder over
# silently, or the next message would report this very chat as "another chat".
case "$SOURCE" in
  clear|compact|resume) [ -n "$CHAT" ] && "$PY" .claude/scripts/cg_session.py claim --chat "$CHAT" >/dev/null 2>&1 ;;
esac
REL_DIR=$("$PY" .claude/scripts/cg_session.py dir 2>/dev/null)
[ -z "$REL_DIR" ] && exit 0
SESSION=$(basename "$REL_DIR")
SESSION_DIR="$ROOT/$REL_DIR"

STATE=$(cat "$SESSION_DIR/state" 2>/dev/null | tr -d '[:space:]')
[ -z "$STATE" ] && exit 0

# Commits the session logged that no branch holds any more. Usually a squash, amend or rebase
# rewrote them; sometimes work was really reset. Report only: rewriting the state on a guess
# stranded sessions with an open PR/MR in PLAN_APPROVED. `rev-parse`: in a worktree .git is a file.
AUDIT_LOG="$SESSION_DIR/audit.log"
if [ -f "$AUDIT_LOG" ] && git rev-parse --git-dir >/dev/null 2>&1; then
  LOGGED_SHAS=$(grep -oE 'commit: [a-f0-9]{7,40}' "$AUDIT_LOG" 2>/dev/null | awk '{print $2}' | sort -u)
  MISSING=""
  for SHA in $LOGGED_SHAS; do
    HELD=""
    git cat-file -e "$SHA^{commit}" 2>/dev/null &&
      HELD=$(git for-each-ref --contains "$SHA" --count=1 refs/heads refs/remotes 2>/dev/null)
    if [ -z "$HELD" ]; then
      MISSING="$MISSING $SHA"
    fi
  done
  if [ -n "$MISSING" ]; then
    echo "Commits logged in this session are not reachable from any branch:$MISSING"
    echo "A squash, amend or rebase rewrites them; a reset drops them."
    echo "If work was really lost, set the session state by hand (it is $STATE)."
    echo ""
  fi
fi

case "$STATE" in
  MERGED|ABANDONED) exit 0 ;;
esac

TASK=$(head -1 "$SESSION_DIR/task.md" 2>/dev/null || echo "(task description not found)")
MODE=$(cat "$SESSION_DIR/mode" 2>/dev/null | tr -d '[:space:]')

echo "CODEGATE TASK ON THIS BRANCH"
echo ""
echo "Session : $SESSION ($REL_DIR)"
echo "State   : $STATE  mode: ${MODE:-interactive}"
echo "Task    : $TASK"
echo ""

case "$STATE" in
  IDLE)
    if [ -f "$SESSION_DIR/PLAN.md" ] && [ ! -f "$SESSION_DIR/elicitation.md" ]; then
      echo "▶ Cosmetic fast path proposed (mini-plan: $REL_DIR/PLAN.md): /cg-approve quick to implement, /cg-approve elicit for the full workflow."
    elif [ -f "$SESSION_DIR/requirements.md" ]; then
      echo "▶ Elicitation complete ($REL_DIR/requirements.md): /cg-approve elicit to plan."
    elif [ -f "$SESSION_DIR/elicitation.md" ]; then
      echo "▶ Elicitation (skill cg-phase-1): a round is open — rounds and answers so far: $REL_DIR/elicitation.md"
    else
      echo "▶ Elicitation (skill cg-phase-1): not started."
    fi
    ;;
  ELICITED)
    echo "▶ Planning (skill cg-phase-2). Elicitation is in $REL_DIR/elicitation.md"
    ;;
  PLAN_APPROVED|IMPLEMENTING)
    echo "▶ Implementation (skill cg-phase-3): continue from the first unchecked item of PLAN.md."
    PLAN_FILE="$SESSION_DIR/PLAN.md"
    if [ -f "$PLAN_FILE" ]; then
      UNCHECKED=$(grep -E '^\s*\[ \]' "$PLAN_FILE" 2>/dev/null | head -7)
      if [ -n "$UNCHECKED" ]; then
        echo "  Remaining items:"
        echo "$UNCHECKED" | while IFS= read -r line; do echo "    $line"; done
      else
        echo "  All checklist items appear complete — next is the quality gate (skill cg-phase-4)."
      fi
    fi
    ;;
  QUALITY_REVIEWED)
    if "$PY" .claude/scripts/cg_session.py checked 2>/dev/null; then
      echo "▶ Gate and independent review done. Next: the PR/MR (skill cg-phase-5)."
    else
      echo "▶ Quality gate done (report: $REL_DIR/QUALITY_REPORT.md). Next: fix rounds, then the independent review (skill cg-phase-4, §4–5)."
    fi
    ;;
  PR_CREATED|PR_UPDATED)
    echo "▶ The PR/MR exists. Fixes to it are rework (skill cg-rework); other code changes are a new task (skill cg-phase-0)."
    ;;
  REWORK)
    echo "▶ Rework on the open PR/MR (skill cg-rework): finish the fix and the delta check before pushing."
    ;;
  *)
    echo "▶ State '$STATE' — check /cg-status."
    ;;
esac
echo ""

DECISIONS_DIR="$SESSION_DIR/decisions"
if [ -d "$DECISIONS_DIR" ]; then
  DECISION_TITLES=$(ls -1 "$DECISIONS_DIR"/*.md 2>/dev/null | sort | tail -4 | while IFS= read -r adr; do
    grep -m1 '^# ' "$adr" 2>/dev/null | sed 's/^# //'
  done)
  if [ -n "$DECISION_TITLES" ]; then
    echo "Recent decisions (see decisions/ for detail):"
    echo "$DECISION_TITLES" | while IFS= read -r line; do echo "  • $line"; done
    echo ""
  fi
fi

exit 0
