#!/bin/bash
# pre-push.sh
# Fires before any git push.
# Two gates:
#   1. Direct push to a protected branch (main / master / release*) is blocked
#      unless the one-shot marker `.ai/protected-target-allowed` exists.
#   2. Push of the task's own branch (the session bound to the checked-out
#      branch) is blocked until the quality gate has passed, during rework,
#      and when it carries commits made after the last check (checked-sha).
#      Exit 2: Claude Code blocks on nothing else.

# Python runs every check below. Without it the parsing silently yields nothing and the hook
# would let everything through; the Windows Store stub `python3` exists but does not run.
PY=$(command -v python3 2>/dev/null)
"${PY:-false}" -c "" 2>/dev/null || PY=$(command -v python 2>/dev/null)
if ! "${PY:-false}" -c "" 2>/dev/null; then
  echo "codegate: Python 3 not found (python3 or python) — this hook cannot check the call. Install Python 3." >&2
  exit 2
fi

INPUT=$(cat 2>/dev/null || echo "")
COMMAND=$("$PY" -c "
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
# Every branch this push can land on: the pushed refspec's destination, and the target of an
# MR the push creates (GitLab `-o merge_request.target=X`) — a protected one either way is gated.
# Parsed with shlex: option values may be quoted and contain spaces (`-o merge_request.title="A b"`).
TARGETS=$(COMMAND="$COMMAND" "$PY" -c '
import os, shlex
try:
    words = shlex.split(os.environ["COMMAND"])
except ValueError:
    words = os.environ["COMMAND"].split()
if "push" in words:
    words = words[words.index("push") + 1:]
positional, options, i = [], [], 0
while i < len(words):
    w = words[i]
    if w in ("-o", "--push-option") and i + 1 < len(words):
        options.append(words[i + 1]); i += 1
    elif w.startswith("--push-option="):
        options.append(w.split("=", 1)[1])
    elif w.startswith("-o") and len(w) > 2:
        options.append(w[2:])
    elif not w.startswith("-"):
        positional.append(w)
    i += 1

def branch(ref):
    ref = ref.lstrip("+")
    for prefix in ("refs/heads/", "heads/"):
        if ref.startswith(prefix):
            return ref[len(prefix):]
    return ref

# Every refspec, not just the last: `git push origin a:main b:x` lands on main too.
dests = [branch(r.rsplit(":", 1)[-1] if ":" in r else r) for r in positional[1:]]
print(" ".join(d or "HEAD" for d in dests) or "HEAD")

mr = [o.split("=", 1)[1] for o in options if o.startswith("merge_request.target=")]
if mr:
    print(mr[-1])
elif "merge_request.create" in options:
    print("@default")  # GitLab opens it against the default branch
' 2>/dev/null)
REF_TARGETS=$(echo "$TARGETS" | sed -n 1p)
MR_TARGET=$(echo "$TARGETS" | sed -n 2p)

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
CHECKS=""
for t in $REF_TARGETS; do
  [ "$t" = "HEAD" ] && t="$CURRENT_BRANCH"
  CHECKS="$CHECKS $t"
done
[ -z "$REF_TARGETS" ] && CHECKS="$CURRENT_BRANCH"
if [ "$MR_TARGET" = "@default" ]; then
  MR_TARGET=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  # Unknown default branch: assume the worst rather than let the MR through unchecked.
  [ -z "$MR_TARGET" ] && MR_TARGET="main"
fi
case "$MR_TARGET" in
  *'$'*|*'`'*) MR_TARGET="main" ;;  # an unexpanded variable can be anything — treat as protected
esac
CHECKS="$CHECKS $MR_TARGET"

for CHECK in $CHECKS; do
[ -z "$CHECK" ] && continue
case "$CHECK" in
  main|master|release*)
    MARKER=".ai/protected-target-allowed"
    if [ -f "$MARKER" ]; then
      rm -f "$MARKER"
      # Continue to gate 2 (session check) — marker only bypasses gate 1
    else
      cat >&2 <<EOF
Push blocked: target branch is '$CHECK' (protected).

Direct pushes to protected branches bypass review. Either:
  - Push to a feature branch and open a PR/MR against a non-protected base, or
  - If you really mean to land on '$CHECK', approve once:
      touch .ai/protected-target-allowed
    then re-run the push. The marker is one-shot.
EOF
      exit 2
    fi
    ;;
esac
done

# --- Gate 2: the task's own checks ---
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SESSION_DIR=$(cd "$ROOT" && "$PY" .claude/scripts/cg_session.py dir 2>/dev/null)
[ -z "$SESSION_DIR" ] && exit 0
SESSION=$(basename "$SESSION_DIR")
SESSION_DIR="$ROOT/$SESSION_DIR"

STATE=$(cat "$SESSION_DIR/state" 2>/dev/null | tr -d '[:space:]')

# The session holds back only its own branch. Without this, a pointer left on another task
# blocked unrelated pushes; sessions that predate the `branch` file keep the old, wider rule.
SESSION_BRANCH=$(cat "$SESSION_DIR/branch" 2>/dev/null | tr -d '[:space:]')
if [ -n "$SESSION_BRANCH" ]; then
  OWN=""
  for t in ${REF_TARGETS:-HEAD}; do
    [ "$t" = "HEAD" ] && t="$CURRENT_BRANCH"
    [ "$t" = "$SESSION_BRANCH" ] && OWN=1
  done
  [ -z "$OWN" ] && exit 0
fi

block() {
  TASK=$(head -1 "$SESSION_DIR/task.md" 2>/dev/null || echo "unknown task")
  {
    echo ""
    echo "PUSH BLOCKED: $1"
    echo ""
    echo "Session : $SESSION"
    echo "Task    : $TASK"
    echo "State   : $STATE"
    echo ""
    echo "$2"
    echo ""
    echo "Only if the user explicitly wants this push unchecked: touch .ai/push-unchecked-allowed"
    echo "and push again (one-shot), and record their reason in the audit log."
    echo ""
  } >&2
  exit 2
}

if [ -f .ai/push-unchecked-allowed ]; then
  rm -f .ai/push-unchecked-allowed
  exit 0
fi

case "$STATE" in
  IDLE|ELICITED|PLAN_APPROVED|IMPLEMENTING)
    block "the task has not passed the quality gate." \
          "Finish implementation and the quality gate (skills cg-phase-3, cg-phase-4); Phase 5 pushes."
    ;;
  REWORK)
    block "rework on this MR has not been checked." \
          "Run the delta check (skill cg-rework), write checked-sha and PR_UPDATED, then push."
    ;;
esac

# Commits after the last check (checked-sha, written by the gate and the rework check) reach
# the MR unreviewed: in practice most post-MR fixes were pushed that way. Merges of the target
# branch and commits touching only .ai/ do not count.
CHECKED=$(cat "$SESSION_DIR/checked-sha" 2>/dev/null | tr -d '[:space:]')
if [ -z "$CHECKED" ] && [ -n "$SESSION_BRANCH" ]; then
  # A session bound to a branch records checked-sha whenever the gate concludes (PASS, WARN
  # accepted, FAIL overridden). Without it the gate has not concluded, whatever the state says.
  case "$STATE" in
    QUALITY_REVIEWED|PR_CREATED|PR_UPDATED)
      block "no checked commit is recorded (checked-sha) — the quality gate has not concluded." \
            "Finish the gate (skill cg-phase-4): PASS, an accepted WARN or the user's /cg-approve quality writes checked-sha."
      ;;
  esac
elif [ -z "$CHECKED" ] && [ "$STATE" = QUALITY_REVIEWED ] && grep -qiE 'verdict[^a-z]*FAIL' "$SESSION_DIR/QUALITY_REPORT.md" 2>/dev/null; then
  block "the quality gate verdict is FAIL." \
        "Fix the FAIL items and re-run the gate on the fixes (skill cg-phase-4), or the user overrides with /cg-approve quality."
fi
TIP=$(git rev-parse --verify --quiet "${SESSION_BRANCH:-HEAD}" 2>/dev/null || git rev-parse HEAD)
if [ -n "$CHECKED" ] && [ -n "$TIP" ]; then
  if ! git merge-base --is-ancestor "$CHECKED" "$TIP" 2>/dev/null; then
    block "the last checked commit ($CHECKED) is no longer in this branch (amend, rebase or reset)." \
          "Treat it as rework: write REWORK and run the delta check against the target branch (skill cg-rework)."
  fi
  # Commits the target branch already has came in by a merge — not this task's to check.
  TARGET=$(cat "$SESSION_DIR/target-branch" 2>/dev/null | tr -d '[:space:]')
  NOT_TARGET=""
  for ref in "origin/$TARGET" "$TARGET"; do
    [ -n "$TARGET" ] && git rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 && { NOT_TARGET="--not $ref"; break; }
  done
  # A merge counts only for what its author changed while resolving it (--remerge-diff, git
  # 2.36+); older git cannot tell that apart, so merges are skipped there.
  MERGES="--no-merges"
  git log -1 --remerge-diff --format= >/dev/null 2>&1 && MERGES="--remerge-diff"
  UNCHECKED=$(git log $MERGES --format= --name-only "$CHECKED..$TIP" $NOT_TARGET 2>/dev/null | grep -v '^$' | grep -v '^\.ai/' | sort -u)
  if [ -n "$UNCHECKED" ]; then
    block "commits after the last check change: $(echo $UNCHECKED | cut -c1-200)" \
          "That is rework: write REWORK with the reason, run the delta check (skill cg-rework), then push."
  fi
fi

exit 0
