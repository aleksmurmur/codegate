#!/bin/bash
# pre-push.sh
# Fires before any git push.
# Blocks the push if an active session has not passed the quality gate.

CURRENT_SESSION_FILE=".ai/current-session"
if [ ! -f "$CURRENT_SESSION_FILE" ]; then
  exit 0
fi

SESSION=$(cat "$CURRENT_SESSION_FILE" 2>/dev/null | tr -d '[:space:]')
if [ -z "$SESSION" ]; then
  exit 0
fi

STATE_FILE=".ai/sessions/$SESSION/state"
STATE=$(cat "$STATE_FILE" 2>/dev/null | tr -d '[:space:]' || echo "")

# These states mean quality gate has not passed yet
case "$STATE" in
  IDLE|ELICITED|PLAN_APPROVED|IMPLEMENTING)
    TASK=$(cat ".ai/sessions/$SESSION/task.md" 2>/dev/null | head -1 || echo "unknown task")
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║              PUSH BLOCKED                    ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    echo "Active session has not passed the quality gate."
    echo ""
    echo "Session : $SESSION"
    echo "Task    : $TASK"
    echo "State   : $STATE"
    echo ""
    echo "Complete the workflow first:"
    echo "  1. Finish implementation"
    echo "  2. Type /cg-approve implementation  (commits + runs quality gate)"
    echo "  3. Fix any quality gate failures"
    echo "  4. Then push via /cg-approve quality or Phase 5 PR creation"
    echo ""
    echo "To push anyway (bypassing the workflow), delete .ai/current-session first."
    echo ""
    exit 1
    ;;
  QUALITY_REVIEWED|PR_CREATED|"")
    # Quality gate passed or no active session — allow push
    exit 0
    ;;
  *)
    # Unknown state — allow push, don't block on unexpected values
    exit 0
    ;;
esac
