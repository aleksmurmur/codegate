#!/bin/bash
# pre-push.sh
# Fires before any git push.
# Two gates:
#   1. Direct push to a protected branch (main / master / release*) is blocked
#      unless the one-shot marker `.ai/protected-target-allowed` exists.
#   2. Push from inside an active codegate session is blocked unless the
#      quality gate has passed.

INPUT=$(cat 2>/dev/null || echo "")
COMMAND=$(python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
" <<< "$INPUT" 2>/dev/null || echo "")

# --- Gate 1: protected-target landings ---
# Determine target branch from the push command.
# Strip "git push" and any flags, then look at remaining args:
#   git push                       → target = current branch
#   git push origin                → target = current branch
#   git push origin main           → target = main
#   git push origin HEAD:main      → target = main
#   git push origin feat:main      → target = main
#   git push origin :main          → target = main (delete)
TARGET=""
if [ -n "$COMMAND" ]; then
  # Everything after "git push", flags filtered out
  ARGS=$(echo "$COMMAND" \
         | sed -E 's/^.*git[[:space:]]+push[[:space:]]*//' \
         | tr ' ' '\n' \
         | grep -v '^-' \
         | grep -v '^$')
  REFSPECS=$(echo "$ARGS" | tail -n +2)
  if [ -n "$REFSPECS" ]; then
    for r in $REFSPECS; do
      case "$r" in
        *:*) TARGET="${r##*:}" ;;
        *)   TARGET="$r" ;;
      esac
    done
  fi
fi
if [ -z "$TARGET" ]; then
  TARGET=$(git branch --show-current 2>/dev/null || echo "")
fi

case "$TARGET" in
  main|master|release*)
    MARKER=".ai/protected-target-allowed"
    if [ -f "$MARKER" ]; then
      rm -f "$MARKER"
      # Continue to gate 2 (session check) — marker only bypasses gate 1
    else
      cat >&2 <<EOF
Push blocked: target branch is '$TARGET' (protected).

Direct pushes to protected branches bypass review. Either:
  - Push to a feature branch and open a PR/MR against a non-protected base, or
  - If you really mean to push to '$TARGET', approve once:
      touch .ai/protected-target-allowed
    then re-run the push. The marker is one-shot.
EOF
      exit 2
    fi
    ;;
esac

# --- Gate 2: active-session quality gate ---
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
    echo "PUSH BLOCKED: active session has not passed the quality gate."
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
