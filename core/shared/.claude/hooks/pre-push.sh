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
# Every branch this push can land on: the pushed refspec's destination, and the target of an
# MR the push creates (GitLab `-o merge_request.target=X`) — a protected one either way is gated.
# Parsed with shlex: option values may be quoted and contain spaces (`-o merge_request.title="A b"`).
TARGETS=$(COMMAND="$COMMAND" python3 -c '
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
