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

# Runs on every Bash call (a hook matcher names a tool, not a command): anything that is not a
# git push leaves at once, before Python is even looked for.
INPUT=$(cat 2>/dev/null || echo "")
case "$INPUT" in *push*) ;; *) exit 0 ;; esac

# Python runs every check below; the Windows Store stub `python3` exists but does not run.
# Without it, only a call that looks like `git [options] push` is held back.
PY=$(command -v python3 2>/dev/null)
"${PY:-false}" -c "" 2>/dev/null || PY=$(command -v python 2>/dev/null)
if ! "${PY:-false}" -c "" 2>/dev/null; then
  if printf '%s' "$INPUT" | grep -qE '(^|[^[:alnum:]_.-]|\\n)git(\.exe)?([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+push([^[:alnum:]_-]|$)'; then
    echo "codegate: Python 3 not found (python3 or python) — this hook cannot check the push. Install Python 3." >&2
    exit 2
  fi
  exit 0
fi

# Only a real `git [options] push`, in any part of a compound command, `bash -c` or `eval` —
# not a commit message or a grep that mentions the word. One line per landing: `ref <branch>`
# (HEAD for the current branch) and `mr <target>` for an MR the push opens.
SCRIPTS="$(cd "$(dirname "$0")" && pwd)/../scripts"
PUSH=$(printf '%s' "$INPUT" | "$PY" "$SCRIPTS/cg_cmd.py" push 2>/dev/null)
case $? in
  0) ;;
  1) exit 0 ;;
  *) echo "codegate: cannot parse this command ($SCRIPTS/cg_cmd.py failed) — the push is not checked." >&2; exit 2 ;;
esac
REF_TARGETS=$(printf '%s\n' "$PUSH" | sed -n 's/^ref //p')
MR_TARGETS=$(printf '%s\n' "$PUSH" | sed -n 's/^mr //p')

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 2
# The markers are the user's one-shot approvals. Only a push that goes through uses them up:
# one blocked by the second gate does not make the user approve the first one again.
CONSUME=""
trap 'rc=$?; [ $rc -eq 0 ] && [ -n "$CONSUME" ] && rm -f $CONSUME; exit $rc' EXIT

SESSION_DIR=$("$PY" "$SCRIPTS/cg_session.py" dir 2>/dev/null)
[ -n "$SESSION_DIR" ] && SESSION_DIR="$ROOT/$SESSION_DIR"
SESSION_TARGET=""
[ -n "$SESSION_DIR" ] && SESSION_TARGET=$(cat "$SESSION_DIR/target-branch" 2>/dev/null | tr -d '[:space:]')

# --- Gate 1: protected-target landings ---
# A pushed refspec that lands on a protected branch, or an MR the push opens against one. The
# MR the task was set up for (Phase 0 recorded its target) is not a stray landing.
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
CHECKS=""
for t in $REF_TARGETS; do
  [ "$t" = "HEAD" ] && t="$CURRENT_BRANCH"
  CHECKS="$CHECKS $t"
done
for t in $MR_TARGETS; do
  case "$t" in
    @default)
      t=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
      # Unknown default branch: assume the worst rather than let the MR through unchecked.
      [ -z "$t" ] && t="main"
      ;;
    @unknown) t="main" ;;  # an unexpanded variable can be anything — treat as protected
  esac
  [ -n "$SESSION_TARGET" ] && [ "$t" = "$SESSION_TARGET" ] && continue
  CHECKS="$CHECKS $t"
done

for CHECK in $CHECKS; do
case "$CHECK" in
  main|master|release*)
    if [ -f .ai/protected-target-allowed ]; then
      CONSUME=".ai/protected-target-allowed"
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
[ -z "$SESSION_DIR" ] && exit 0
SESSION=$(basename "$SESSION_DIR")

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
  CONSUME="$CONSUME .ai/push-unchecked-allowed"
  exit 0
fi

case "$STATE" in
  IDLE|ELICITED|PLAN_APPROVED|IMPLEMENTING)
    block "the task has not passed the quality gate." \
          "Finish implementation and the quality gate (skills cg-phase-3, cg-phase-4); Phase 5 pushes."
    ;;
  REWORK)
    block "rework on this PR/MR has not been checked." \
          "Run the delta check (skill cg-rework), write checked-sha and PR_UPDATED, then push."
    ;;
esac

# Commits after the last check (checked-sha, written at the end of Phase 4 and by the rework check) reach
# the PR/MR unreviewed. Merges of the target branch and commits touching only .ai/ do not count.
CHECKED=$(cat "$SESSION_DIR/checked-sha" 2>/dev/null | tr -d '[:space:]')
if [ -z "$CHECKED" ] && [ -n "$SESSION_BRANCH" ]; then
  # A session bound to a branch records checked-sha whenever the gate concludes (PASS, WARN
  # accepted, FAIL overridden). Without it the gate has not concluded, whatever the state says.
  case "$STATE" in
    QUALITY_REVIEWED|PR_CREATED|PR_UPDATED)
      block "no checked commit is recorded (checked-sha) — the quality gate has not concluded." \
            "Finish Phase 4 (skill cg-phase-4): the gate, then the independent review, which writes checked-sha."
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
  NOT_TARGET=""
  for ref in "origin/$SESSION_TARGET" "$SESSION_TARGET"; do
    [ -n "$SESSION_TARGET" ] && git rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 && { NOT_TARGET="--not $ref"; break; }
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
