#!/bin/bash
# pre-write.sh
# Blocks Write/Edit on source files until plan is approved.
# Writes to .ai/ are always allowed (session state, plans, reports).

# Python runs every check below. Without it the parsing silently yields nothing and the hook
# would let everything through; the Windows Store stub `python3` exists but does not run.
PY=$(command -v python3 2>/dev/null)
"${PY:-false}" -c "" 2>/dev/null || PY=$(command -v python 2>/dev/null)
if ! "${PY:-false}" -c "" 2>/dev/null; then
  echo "codegate: Python 3 not found (python3 or python) — this hook cannot check the call. Install Python 3." >&2
  exit 2
fi

INPUT=$(cat)
# The checkout the call runs in is the `cwd` the hook is given, not the hook process's.
CWD=$("$PY" -c "import json,sys; print(json.load(sys.stdin).get('cwd') or '')" <<< "$INPUT" 2>/dev/null)
[ -n "$CWD" ] && cd "$CWD" 2>/dev/null

# Extract file path from tool input (works for both Write and Edit)
FILE=$("$PY" -c "
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

[ -z "$FILE" ] && exit 0

# Guard this repository only. A file in another directory (/tmp, a sibling project) is not this
# task's source; blocking it only taught agents to write through the shell. A file in another
# worktree of this repository is judged by that worktree's task.
# Compare git's own answers rather than path strings: one path arrives in several spellings.
# REL is the path inside this checkout, so the allowlists below cannot be satisfied by a
# directory that merely contains `.claude/` — task worktrees live under .claude/worktrees/.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
common_dir() { local d; d=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) && (cd "$1" && cd "$d" && pwd -P); }
REL="$FILE_NORM"
if [ -n "$REPO_ROOT" ]; then
  case "$FILE_NORM" in
    /*|?:/*)
      DIR=$(dirname "$FILE_NORM")
      while [ ! -d "$DIR" ] && [ "$DIR" != "$(dirname "$DIR")" ]; do DIR=$(dirname "$DIR"); done
      FILE_ROOT=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)
      if [ "$FILE_ROOT" != "$REPO_ROOT" ]; then
        [ -n "$FILE_ROOT" ] && [ "$(common_dir "$DIR")" = "$(common_dir "$REPO_ROOT")" ] || exit 0
        REPO_ROOT="$FILE_ROOT"
        cd "$REPO_ROOT" || exit 2
      fi
      REL="$(git -C "$DIR" rev-parse --show-prefix 2>/dev/null)${FILE_NORM#"$DIR"/}"
      ;;
    *)
      REL="$(git rev-parse --show-prefix 2>/dev/null)${FILE_NORM#./}"
      ;;
  esac
  # Session data and the workflow's own files: always writable.
  case "$REL" in
    .ai/*) exit 0 ;;
    .claude/worktrees/*) ;;
    .claude/*) exit 0 ;;
  esac
else
  # Outside git there is no root to anchor on: match anywhere in the path.
  if [[ "$FILE_NORM" == .ai/* ]] || [[ "$FILE_NORM" == */.ai/* ]] ||      [[ "$FILE_NORM" == .claude/* ]] || [[ "$FILE_NORM" == */.claude/* ]]; then
    exit 0
  fi
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

# The task of this checkout: the session bound to the branch checked out here.
ROOT=${REPO_ROOT:-$(pwd)}
SESSION_DIR=$(cd "$ROOT" && "$PY" .claude/scripts/cg_session.py dir 2>/dev/null)
if [ -z "$SESSION_DIR" ]; then
  echo "No task on branch '$(git branch --show-current 2>/dev/null)'. Start one (/cg-feature, /cg-bugfix, /cg-refactor — skill cg-phase-0) before editing source files." >&2
  exit 2
fi

STATE=$(cat "$ROOT/$SESSION_DIR/state" 2>/dev/null | tr -d '[:space:]')

case "$STATE" in
  PLAN_APPROVED|IMPLEMENTING|QUALITY_REVIEWED|REWORK)
    exit 0
    ;;
  IDLE|"")
    echo "Cannot modify '$FILE': state is IDLE. Finish elicitation first (skill cg-phase-1)." >&2
    exit 2
    ;;
  ELICITED)
    echo "Cannot modify '$FILE': state is ELICITED. The plan comes first (skill cg-phase-2)." >&2
    exit 2
    ;;
  PR_CREATED|PR_UPDATED)
    echo "Cannot modify '$FILE': this task's PR/MR is open. A fix to it (QA, review, CI) is rework: write REWORK to $SESSION_DIR/state with the reason in the audit log (skill cg-rework). Other work is a new task (skill cg-phase-0)." >&2
    exit 2
    ;;
  MERGED|ABANDONED)
    echo "Cannot modify '$FILE': this task is closed ($STATE). A defect in it is a new bug task linked to it; other work is a new task (skill cg-phase-0)." >&2
    exit 2
    ;;
  *)
    echo "Cannot modify '$FILE': unexpected state '$STATE'. Check /cg-status." >&2
    exit 2
    ;;
esac
