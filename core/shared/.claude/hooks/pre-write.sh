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

# Normalize the separators before matching anything.
#
# Claude Code hands this hook an ABSOLUTE path, and on Windows that path uses
# backslashes: `D:\project\.ai\PLAN.md` matches neither `.ai/*` nor `*/.ai/*`, so every
# allowlist below silently fell through to the state check and blocked the writes the flow
# itself depends on — an agent could not write its own plan while the state was ELICITED.
# `basename` is equally blind to backslashes, so the config allowlists broke the same way.
# Matching on a forward-slash copy makes one set of patterns work on Windows, macOS and Linux.
FILE_NORM=$(printf '%s' "$FILE" | tr '\' '/' 2>/dev/null)

# Always allow writes to .ai/ (state files, plans, reports, audit logs)
if [[ "$FILE_NORM" == .ai/* ]] || [[ "$FILE_NORM" == */.ai/* ]] || [[ -z "$FILE" ]]; then
  exit 0
fi

# Always allow writes to .claude/ (agent prompts, commands, hooks)
if [[ "$FILE_NORM" == .claude/* ]] || [[ "$FILE_NORM" == */.claude/* ]]; then
  exit 0
fi

# Always allow writes to workflow-config files at the project root. These define the
# workflow itself; editing them is meta-work, not source-code changes, and should not
# require an active session.
BASENAME=$(basename "$FILE_NORM")
case "$BASENAME" in
  CLAUDE.md|README.md|README_*.md|.gitignore)
    exit 0
    ;;
esac

# Always allow writes to linter config files (CIE updates these during /cg-context, which has no session)
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
