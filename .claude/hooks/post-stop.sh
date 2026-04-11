#!/bin/bash
# post-stop.sh
# Fires when the agent stops (Stop event).
# If a session is in IMPLEMENTING state, the quality gate has not run yet.
# Warn the user so they know to continue the session to complete the workflow.

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
  echo "⚠ Quality gate has not run for session: $SESSION"
  echo "  Task: $TASK"
  echo "  State: IMPLEMENTING"
  echo ""
  echo "  The quality gate must complete before a PR can be created."
  echo "  Continue this session — the quality gate runs automatically"
  echo "  when implementation is complete."
  echo ""
  echo "  To check status: /status"
fi

exit 0
