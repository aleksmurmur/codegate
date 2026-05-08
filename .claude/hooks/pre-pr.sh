#!/bin/bash
# pre-pr.sh
# Blocks `gh pr create` / `glab mr create` against protected base branches
# (main, master, release*) unless a one-shot marker exists at
# .ai/protected-target-allowed. The user must consciously approve a PR/MR
# whose target is a protected branch — the typical case is to land on a
# dev / staging / integration branch first.

INPUT=$(cat)

COMMAND=$(python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
" <<< "$INPUT" 2>/dev/null || echo "")

# Only fire on PR/MR-creating commands
case "$COMMAND" in
  *"gh pr create"*|*"glab mr create"*) ;;
  *) exit 0 ;;
esac

# Extract base/target-branch value if explicitly passed (gh: --base/-B, glab: --target-branch)
BASE=$(echo "$COMMAND" | grep -oE -- '(--base|-B|--target-branch)[= ][^[:space:]]+' | head -1 | sed -E 's/^(--base|-B|--target-branch)[= ]//')

# Fall back to repo's default branch (usually main / master)
if [ -z "$BASE" ]; then
  if command -v gh >/dev/null 2>&1; then
    BASE=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo "")
  fi
  if [ -z "$BASE" ] && command -v glab >/dev/null 2>&1; then
    BASE=$(glab repo view --output json 2>/dev/null \
           | python3 -c "import json,sys; print(json.load(sys.stdin).get('default_branch',''))" 2>/dev/null \
           || echo "")
  fi
  [ -z "$BASE" ] && BASE="main"
fi

case "$BASE" in
  main|master|release*)
    MARKER=".ai/protected-target-allowed"
    if [ -f "$MARKER" ]; then
      rm -f "$MARKER"
      exit 0
    fi
    cat >&2 <<EOF
PR/MR creation blocked: target branch is '$BASE' (protected).

If you really mean to land on '$BASE':
  touch .ai/protected-target-allowed
then re-run the command. The marker is one-shot.

Otherwise, change the base — typically a dev/staging branch:
  gh pr create --base dev
  glab mr create --target-branch dev
EOF
    exit 2
    ;;
esac

exit 0
