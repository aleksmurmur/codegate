#!/bin/bash
# post-compact.sh
# Fires on every SessionStart. Detects active mid-task sessions and injects
# recovery context so the agent knows where to resume.
#
# Exits silently (no output) when:
# - No active session exists
# - Session is complete (PR_CREATED)
# - Session files are missing or unreadable

INPUT=$(cat)

# Extract cwd from hook input
CWD=$(python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('cwd', ''))
except Exception:
    print('')
" <<< "$INPUT" 2>/dev/null || echo "")

# Fall back to current directory if cwd not in input
[ -z "$CWD" ] && CWD="$(pwd)"

CURRENT_SESSION_FILE="$CWD/.ai/current-session"
[ -f "$CURRENT_SESSION_FILE" ] || exit 0

SESSION=$(cat "$CURRENT_SESSION_FILE" 2>/dev/null | tr -d '[:space:]')
[ -z "$SESSION" ] && exit 0

SESSION_DIR="$CWD/.ai/sessions/$SESSION"
[ -d "$SESSION_DIR" ] || exit 0

STATE=$(cat "$SESSION_DIR/state" 2>/dev/null | tr -d '[:space:]' || echo "")
[ -z "$STATE" ] && exit 0

# Commits the session logged that no branch holds any more. Usually a squash, amend or rebase
# rewrote them; sometimes work was really reset. Report only: rewriting the state on a guess
# stranded sessions with an open MR in PLAN_APPROVED. `rev-parse`: in a worktree .git is a file.
AUDIT_LOG="$SESSION_DIR/audit.log"
if [ -f "$AUDIT_LOG" ] && git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
  LOGGED_SHAS=$(grep -oE 'commit: [a-f0-9]{7,40}' "$AUDIT_LOG" 2>/dev/null | awk '{print $2}' | sort -u)
  MISSING=""
  for SHA in $LOGGED_SHAS; do
    HELD=""
    git -C "$CWD" cat-file -e "$SHA^{commit}" 2>/dev/null &&
      HELD=$(git -C "$CWD" for-each-ref --contains "$SHA" --count=1 refs/heads refs/remotes 2>/dev/null)
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

# Silent exit for completed sessions — nothing to recover
[ "$STATE" = "PR_CREATED" ] && exit 0

# Silent exit for idle sessions that haven't started real work yet
[ "$STATE" = "IDLE" ] && exit 0

# --- Active session found — output recovery context ---

TASK=$(head -1 "$SESSION_DIR/task.md" 2>/dev/null || echo "(task description not found)")

echo "SESSION RECOVERY CONTEXT"
echo ""
echo "Context was compacted. An active session was found."
echo ""
echo "Session : $SESSION"
echo "State   : $STATE"
echo "Task    : $TASK"
echo ""

# Phase-specific resume instruction
case "$STATE" in
  ELICITED)
    echo "▶ Resume: Elicitation is complete. Planning has not started."
    echo "  Remind the user to type /cg-approve elicit to begin planning."
    echo "  Elicitation Q&A is at: $SESSION_DIR/elicitation.md"
    ;;
  PLAN_APPROVED|IMPLEMENTING)
    echo "▶ Resume: Implementation is in progress."
    echo "  Read PLAN.md and continue from the first unchecked [ ] item."
    echo "  Follow CLAUDE.md Phase 3 instructions."
    echo ""
    # Show remaining checklist items (up to 7)
    PLAN_FILE="$SESSION_DIR/PLAN.md"
    if [ -f "$PLAN_FILE" ]; then
      UNCHECKED=$(grep '^\[ \]' "$PLAN_FILE" 2>/dev/null | head -7)
      if [ -n "$UNCHECKED" ]; then
        echo "  Remaining items:"
        echo "$UNCHECKED" | while IFS= read -r line; do
          echo "    $line"
        done
      else
        echo "  All checklist items appear complete."
        echo "  Type /cg-approve implementation to run the quality gate."
      fi
    fi
    ;;
  QUALITY_REVIEWED)
    echo "▶ Resume: Quality gate is complete. PR has not been created."
    echo "  Proceed to Phase 5: create the PR."
    echo "  Quality report is at: $SESSION_DIR/QUALITY_REPORT.md"
    ;;
  *)
    echo "▶ Resume: State is '$STATE'."
    echo "  Read CLAUDE.md to find the correct phase for this state."
    ;;
esac

echo ""

# Show recent decisions (latest ADR titles — keep output compact)
DECISIONS_DIR="$SESSION_DIR/decisions"
if [ -d "$DECISIONS_DIR" ]; then
  DECISION_TITLES=$(ls -1 "$DECISIONS_DIR"/*.md 2>/dev/null | sort | tail -4 | while IFS= read -r adr; do
    grep -m1 '^# ' "$adr" 2>/dev/null | sed 's/^# //'
  done)
  if [ -n "$DECISION_TITLES" ]; then
    echo "Recent decisions (see decisions/ for detail):"
    echo "$DECISION_TITLES" | while IFS= read -r line; do
      echo "  • $line"
    done
    echo ""
  fi
fi

echo "Session files : $SESSION_DIR/"
echo "Workflow ref  : Read CLAUDE.md for phase instructions"
echo "Manual resume : /resume"
echo ""

exit 0
