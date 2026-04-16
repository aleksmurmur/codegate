#!/bin/bash
# pre-write.sh
# Blocks Write/Edit on source files until plan is approved.
# Writes to .ai/ are always allowed (session state, plans, reports).

INPUT=$(cat)

# Extract file path from tool input (works for both Write and Edit)
FILE=$(python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    inp = data.get('tool_input', {})
    print(inp.get('file_path', inp.get('path', '')))
except Exception:
    print('')
" <<< "$INPUT" 2>/dev/null || echo "")

# Always allow writes to .ai/ (state files, plans, reports, audit logs)
if [[ "$FILE" == .ai/* ]] || [[ "$FILE" == */.ai/* ]] || [[ -z "$FILE" ]]; then
  exit 0
fi

# Always allow writes to .claude/ (agent prompts, commands, hooks)
if [[ "$FILE" == .claude/* ]] || [[ "$FILE" == */.claude/* ]]; then
  exit 0
fi

# Always allow writes to linter config files (CIE updates these during /cg-context, which has no session)
BASENAME=$(basename "$FILE")
case "$BASENAME" in
  .editorconfig|.eslintrc|.eslintrc.js|.eslintrc.cjs|.eslintrc.json|.eslintrc.yml|.eslintrc.yaml|\
  eslint.config.js|eslint.config.cjs|eslint.config.mjs|eslint.config.ts|\
  .prettierrc|.prettierrc.js|.prettierrc.json|.prettierrc.yml|.prettierrc.yaml|prettier.config.js|\
  checkstyle.xml|detekt.yml|detekt.yaml|.detekt.yml|\
  .rubocop.yml|.flake8|ruff.toml|.ruff.toml|pyproject.toml|\
  .golangci.yml|.golangci.yaml|scalafmt.conf|.scalafmt.conf|\
  rustfmt.toml|.rustfmt.toml|clippy.toml|.clippy.toml)
    exit 0
    ;;
esac

# Check active session
CURRENT_SESSION_FILE=".ai/current-session"
if [ ! -f "$CURRENT_SESSION_FILE" ]; then
  echo "No active session. Start a task with /cg-feature, /cg-bugfix, or /cg-refactor before editing source files."
  exit 2
fi

SESSION=$(cat "$CURRENT_SESSION_FILE" 2>/dev/null | tr -d '[:space:]')
if [ -z "$SESSION" ]; then
  echo "Current session file is empty. Start a new task with /cg-feature or /cg-bugfix."
  exit 2
fi

STATE_FILE=".ai/sessions/$SESSION/state"
STATE=$(cat "$STATE_FILE" 2>/dev/null | tr -d '[:space:]' || echo "IDLE")

case "$STATE" in
  PLAN_APPROVED|IMPLEMENTING|QUALITY_REVIEWED|PR_CREATED)
    exit 0
    ;;
  IDLE)
    echo "Cannot modify '$FILE': state is IDLE. Complete elicitation questions first, then run /cg-approve elicit."
    exit 2
    ;;
  ELICITED)
    echo "Cannot modify '$FILE': state is ELICITED. A plan must be created and approved. Run /cg-approve plan after reviewing the plan."
    exit 2
    ;;
  *)
    echo "Cannot modify '$FILE': unexpected state '$STATE'. Check /cg-status."
    exit 2
    ;;
esac
