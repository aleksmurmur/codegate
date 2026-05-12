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

# /rewind reconciliation — if commits logged in audit.log are no longer reachable
# from HEAD (Claude Code /rewind, manual git reset, etc.), revert state so the
# user isn't trapped in a phase whose underlying commits are gone.
AUDIT_LOG="$SESSION_DIR/audit.log"
if [ -f "$AUDIT_LOG" ] && [ -d "$CWD/.git" ]; then
  LOGGED_SHAS=$(grep -oE 'commit: [a-f0-9]{7,40}' "$AUDIT_LOG" 2>/dev/null | awk '{print $2}' | sort -u)
  if [ -n "$LOGGED_SHAS" ]; then
    MISSING=""
    for SHA in $LOGGED_SHAS; do
      git -C "$CWD" merge-base --is-ancestor "$SHA" HEAD 2>/dev/null || MISSING="$MISSING $SHA"
    done
    if [ -n "$MISSING" ]; then
      case "$STATE" in
        IMPLEMENTING|QUALITY_REVIEWED|PR_CREATED)
          OLD_STATE="$STATE"
          echo "PLAN_APPROVED" > "$SESSION_DIR/state"
          STATE="PLAN_APPROVED"
          TS=$(date '+%Y-%m-%dT%H:%M:%S')
          echo "[$TS] /rewind detected — state reverted from $OLD_STATE to PLAN_APPROVED, missing commits:$MISSING" >> "$AUDIT_LOG"
          echo "/REWIND DETECTED"
          echo ""
          echo "Commits logged in audit.log are no longer reachable from HEAD."
          echo "Codegate state has been reverted from $OLD_STATE to PLAN_APPROVED."
          echo "Missing commits:$MISSING"
          echo ""
          ;;
      esac
    fi
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
