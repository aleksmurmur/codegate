#!/bin/bash
# post-stop.sh
# Fires when the agent stops. Checks whether quality gate was run
# for any in-progress implementation session and warns the user if not.

CURRENT_SESSION_FILE=".ai/current-session"
if [ ! -f "$CURRENT_SESSION_FILE" ]; then
  exit 0
fi

SESSION=$(cat "$CURRENT_SESSION_FILE" 2>/dev/null | tr -d '[:space:]')
if [ -z "$SESSION" ]; then
  exit 0
fi

STATE=$(cat ".ai/sessions/$SESSION/state" 2>/dev/null | tr -d '[:space:]' || echo "")

if [ "$STATE" = "IMPLEMENTING" ]; then
  echo ""
  echo "WARNING: Session '$SESSION' is in IMPLEMENTING state but quality gate has not run."
  echo "Before creating a PR, the quality gate must complete."
  echo "Continue the session and the quality gate will run automatically when implementation is done."
fi

exit 0
