#!/bin/bash
# pre-pr.sh
# Blocks `gh pr create` / `glab mr create` against protected base branches
# (main, master, release*) unless a one-shot marker exists at
# .ai/protected-target-allowed. The user must consciously approve a PR/MR
# whose target is a protected branch — the typical case is to land on a
# dev / staging / integration branch first. The PR/MR of the current task to
# the target Phase 0 recorded for it needs no marker.

# Runs on every Bash call (a hook matcher names a tool, not a command): leave at once unless it
# can be a PR/MR creation.
INPUT=$(cat 2>/dev/null || echo "")
case "$INPUT" in *"pr create"*|*"mr create"*) ;; *) exit 0 ;; esac

PY=$(command -v python3 2>/dev/null)
"${PY:-false}" -c "" 2>/dev/null || PY=$(command -v python 2>/dev/null)
if ! "${PY:-false}" -c "" 2>/dev/null; then
  if printf '%s' "$INPUT" | grep -qE '(gh|glab)(\.exe)?[[:space:]]+(pr|mr)[[:space:]]+create'; then
    echo "codegate: Python 3 not found (python3 or python) — this hook cannot check the PR/MR. Install Python 3." >&2
    exit 2
  fi
  exit 0
fi

# One `base <branch>` line per PR/MR creation: `@default` when none is given, `@unknown` when
# it is a variable.
SCRIPTS="$(cd "$(dirname "$0")" && pwd)/../scripts"
BASES=$(printf '%s' "$INPUT" | "$PY" "$SCRIPTS/cg_cmd.py" pr 2>/dev/null)
case $? in
  0) ;;
  1) exit 0 ;;
  *) echo "codegate: cannot parse this command ($SCRIPTS/cg_cmd.py failed) — the PR/MR is not checked." >&2; exit 2 ;;
esac

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 2
SESSION_DIR=$("$PY" "$SCRIPTS/cg_session.py" dir 2>/dev/null)
SESSION_TARGET=""
[ -n "$SESSION_DIR" ] && SESSION_TARGET=$(cat "$SESSION_DIR/target-branch" 2>/dev/null | tr -d '[:space:]')

CONSUME=""
for BASE in $(printf '%s\n' "$BASES" | sed -n 's/^base //p'); do
  if [ "$BASE" = "@default" ]; then
    BASE=""
    if command -v gh >/dev/null 2>&1; then
      BASE=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo "")
    fi
    if [ -z "$BASE" ] && command -v glab >/dev/null 2>&1; then
      BASE=$(glab repo view --output json 2>/dev/null \
             | "$PY" -c "import json,sys; print(json.load(sys.stdin).get('default_branch',''))" 2>/dev/null \
             || echo "")
    fi
    [ -z "$BASE" ] && BASE="main"
  fi
  [ -n "$SESSION_TARGET" ] && [ "$BASE" = "$SESSION_TARGET" ] && continue
  case "$BASE" in
    main|master|release*|@unknown)
      if [ -f .ai/protected-target-allowed ]; then
        CONSUME=1
        continue
      fi
      [ "$BASE" = "@unknown" ] && BASE="a variable — write the branch name out"
      cat >&2 <<EOF
PR/MR creation blocked: target branch is '$BASE' (protected).

If you really mean to land on it:
  touch .ai/protected-target-allowed
then re-run the command. The marker is one-shot.

Otherwise, change the base — typically a dev/staging branch:
  gh pr create --base dev
  glab mr create --target-branch dev
EOF
      exit 2
      ;;
  esac
done

[ -n "$CONSUME" ] && rm -f .ai/protected-target-allowed
exit 0
