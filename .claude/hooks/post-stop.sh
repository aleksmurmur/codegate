#!/bin/bash
# post-stop.sh
# Fires when the agent stops (Stop event).
# If a session is in IMPLEMENTING state, remind the user to approve implementation.

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

if [ "$STATE" = "IMPLEMENTING" ]; then
  TASK=$(cat ".ai/sessions/$SESSION/task.md" 2>/dev/null | head -1 || echo "unknown task")
  echo ""
  echo "IMPLEMENTATION AWAITING APPROVAL"
  echo ""
  echo "Session : $SESSION"
  echo "Task    : $TASK"
  echo ""
  echo "When implementation is complete, type:"
  echo ""
  echo "  /cg-approve implementation"
  echo ""
  echo "This will commit all changes and run the quality gate."
  echo "Do NOT push manually — the quality gate must pass first."
  echo ""
fi

exit 0
