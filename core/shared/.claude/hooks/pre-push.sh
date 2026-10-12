#!/bin/bash
# pre-push.sh
# Fires before any git push and any PR/MR creation (gh pr create, glab mr create).
# Two gates:
#   1. A landing on a protected branch (main / master / release*) — a pushed
#      refspec, an MR opened by push options, a PR/MR created by gh/glab — is
#      blocked unless the one-shot marker `.ai/protected-target-allowed` exists.
#      The task's own branch going to the target Phase 0 recorded is not a stray
#      landing and needs no marker.
#   2. Delivering the task's own branch (the session bound to the checked-out
#      branch) — pushing it or opening its PR/MR — is blocked until the quality
#      gate and the independent review have concluded, during rework, and when it
#      carries commits made after the last check (checked-sha).
#      Exit 2: Claude Code blocks on nothing else.

# Runs on every Bash call (a hook matcher names a tool, not a command): anything that cannot be
# a push or a PR/MR creation leaves at once, before Python is even looked for.
INPUT=$(cat 2>/dev/null || echo "")
case "$INPUT" in *git*|*gh*|*glab*) ;; *) exit 0 ;; esac

# Python runs every check below; the Windows Store stub `python3` exists but does not run.
# Without it, only a call that looks like a push or a PR/MR creation is held back.
PY=$(command -v python3 2>/dev/null)
"${PY:-false}" -c "" 2>/dev/null || PY=$(command -v python 2>/dev/null)
if ! "${PY:-false}" -c "" 2>/dev/null; then
  if printf '%s' "$INPUT" | grep -qE '(^|[^[:alnum:]_.-]|\\n)git(\.exe)?([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+push([^[:alnum:]_-]|$)|(gh|glab)(\.exe)?[[:space:]]+(pr|mr)[[:space:]]+(create|new)'; then
    echo "codegate: Python 3 not found (python3 or python) — this hook cannot check the push or PR/MR. Install Python 3." >&2
    exit 2
  fi
  exit 0
fi

# One line per landing (see cg_cmd.py): `ref <dest> <source>`, `mr <target>`, `base <branch> <head>`.
SCRIPTS="$(cd "$(dirname "$0")" && pwd)/../scripts"
LANDINGS=$(printf '%s' "$INPUT" | "$PY" "$SCRIPTS/cg_cmd.py" 2>/dev/null)
case $? in
  0) ;;
  1) exit 0 ;;
  3) echo "codegate: this command looks like a push or a PR/MR creation but cannot be parsed (unbalanced quotes?). Run it as a plain command." >&2; exit 2 ;;
  *) echo "codegate: cannot parse this command ($SCRIPTS/cg_cmd.py failed) — the push or PR/MR is not checked." >&2; exit 2 ;;
esac

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 2
# The markers are the user's one-shot approvals. Only a call that goes through uses them up:
# one blocked by the second gate does not make the user approve the first one again.
CONSUME=""
trap 'rc=$?; [ $rc -eq 0 ] && [ -n "$CONSUME" ] && rm -f $CONSUME; exit $rc' EXIT

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
# The session of the checked-out branch; on a detached HEAD, the session of a branch this call
# pushes to — pushing `HEAD:<task branch>` from there delivers that task too.
LOOKUP=""
if [ -z "$CURRENT_BRANCH" ]; then
  LOOKUP=$(printf '%s
' "$LANDINGS" | while read -r kind a b; do
    [ "$kind" = ref ] && [ "$a" != HEAD ] && "$PY" "$SCRIPTS/cg_session.py" branch --branch "$a" 2>/dev/null && break
  done | head -1)
fi
SESSION_DIR=$("$PY" "$SCRIPTS/cg_session.py" dir ${LOOKUP:+--branch "$LOOKUP"} 2>/dev/null)
SESSION_TARGET=""
SESSION_BRANCH=""
if [ -n "$SESSION_DIR" ]; then
  SESSION_DIR="$ROOT/$SESSION_DIR"
  SESSION_TARGET=$(cat "$SESSION_DIR/target-branch" 2>/dev/null | tr -d '[:space:]')
  SESSION_BRANCH=$("$PY" "$SCRIPTS/cg_session.py" branch ${LOOKUP:+--branch "$LOOKUP"} 2>/dev/null)
fi
here() { [ "$1" = "HEAD" ] && echo "$CURRENT_BRANCH" || echo "$1"; }

default_branch() {
  local b=""
  case "$1" in
    push) b=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##') ;;
    pr)
      command -v gh >/dev/null 2>&1 && b=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null)
      [ -z "$b" ] && command -v glab >/dev/null 2>&1 && b=$(glab repo view --output json 2>/dev/null \
        | "$PY" -c "import json,sys; print(json.load(sys.stdin).get('default_branch',''))" 2>/dev/null)
      ;;
  esac
  # Unknown default branch: assume the worst rather than let the PR/MR through unchecked.
  echo "${b:-main}"
}

# --- Collect the landings: protected ones for gate 1, deliveries of the task's branch for gate 2 ---
PROTECTED=""
OWN_TIPS=""
OWN=""
ALL_REFS_OWN=1
while read -r kind a b; do
  [ "$kind" = "ref" ] || continue
  dest=$(here "$a")
  [ -n "$SESSION_BRANCH" ] && [ "$dest" = "$SESSION_BRANCH" ] || ALL_REFS_OWN=""
  case "$dest" in main|master|release*|@all) PROTECTED="$PROTECTED $dest" ;; esac
  if [ -z "$SESSION_BRANCH" ] || [ "$dest" = "$SESSION_BRANCH" ] || [ "$dest" = "@all" ]; then
    [ "$b" = "-" ] && continue  # a deletion carries no code
    OWN=1
    src="$b"
    [ "$dest" = "@all" ] && [ -n "$SESSION_BRANCH" ] && src="$SESSION_BRANCH"
    OWN_TIPS="$OWN_TIPS $(git rev-parse --verify --quiet "$src^{commit}" 2>/dev/null || git rev-parse HEAD)"
  fi
done <<< "$LANDINGS"

while read -r kind a b; do
  case "$kind" in
    mr)
      t="$a"
      [ "$t" = "@default" ] && t=$(default_branch push)
      [ "$t" = "@unknown" ] && t="@unknown"  # an unexpanded variable can be anything
      # The task's own branch opening its MR to the recorded target: gate 2 covers it.
      [ -n "$SESSION_TARGET" ] && [ "$t" = "$SESSION_TARGET" ] && [ -n "$ALL_REFS_OWN" ] && continue
      ;;
    base)
      t="$a"
      [ "$t" = "@default" ] && t=$(default_branch pr)
      head=$(here "$b")
      if [ -n "$SESSION_BRANCH" ] && [ "$head" = "$SESSION_BRANCH" ]; then
        OWN=1
        OWN_TIPS="$OWN_TIPS $(git rev-parse --verify --quiet "$SESSION_BRANCH^{commit}" 2>/dev/null)"
        [ "$t" = "$SESSION_TARGET" ] && continue
      fi
      ;;
    *) continue ;;
  esac
  case "$t" in main|master|release*|@unknown) PROTECTED="$PROTECTED $t" ;; esac
done <<< "$LANDINGS"

# --- Gate 1: protected landings ---
PROTECTED=$(echo $PROTECTED | tr ' ' '
' | sort -u | tr '
' ' ')
COUNT=$(echo $PROTECTED | wc -w | tr -d ' ')
if [ "$COUNT" -gt 1 ]; then
  echo "Blocked: this call lands on several protected branches ($PROTECTED). One approval covers one landing — split the command." >&2
  exit 2
fi
if [ "$COUNT" -eq 1 ]; then
  CHECK=$(echo $PROTECTED)
  [ "$CHECK" = "@unknown" ] && CHECK="a variable — write the branch name out"
  [ "$CHECK" = "@all" ] && CHECK="every branch (--all / --mirror)"
  if [ -f .ai/protected-target-allowed ]; then
    CONSUME=".ai/protected-target-allowed"
  else
    cat >&2 <<EOF
Blocked: target branch is '$CHECK' (protected).

Landing on a protected branch bypasses review. Either:
  - push to a feature branch and open the PR/MR against a non-protected base, or
  - if you really mean to land on '$CHECK', approve once:
      touch .ai/protected-target-allowed
    then re-run the command. The marker is one-shot.
EOF
    exit 2
  fi
fi

# --- Gate 2: the task's own checks ---
[ -z "$SESSION_DIR" ] && exit 0
[ -z "$OWN" ] && exit 0
SESSION=$(basename "$SESSION_DIR")
STATE=$(cat "$SESSION_DIR/state" 2>/dev/null | tr -d '[:space:]')

block() {
  TASK=$(head -1 "$SESSION_DIR/task.md" 2>/dev/null || echo "unknown task")
  {
    echo ""
    echo "BLOCKED: $1"
    echo ""
    echo "Session : $SESSION"
    echo "Task    : $TASK"
    echo "State   : $STATE"
    echo ""
    echo "$2"
    echo ""
    echo "Only if the user explicitly wants this unchecked: touch .ai/push-unchecked-allowed"
    echo "and run it again (one-shot), and record their reason in the audit log."
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
  # A session bound to a branch records checked-sha when the independent review concludes.
  # Without it Phase 4 has not concluded, whatever the state says.
  case "$STATE" in
    QUALITY_REVIEWED|PR_CREATED|PR_UPDATED)
      block "no checked commit is recorded (checked-sha) — Phase 4 has not concluded." \
            "Finish Phase 4 (skill cg-phase-4): the gate, then the independent review, which writes checked-sha."
      ;;
  esac
elif [ -z "$CHECKED" ] && [ "$STATE" = QUALITY_REVIEWED ] && grep -qiE 'verdict[^a-z]*FAIL' "$SESSION_DIR/QUALITY_REPORT.md" 2>/dev/null; then
  block "the quality gate verdict is FAIL." \
        "Fix the FAIL items and re-run the gate on the fixes (skill cg-phase-4), or the user overrides with /cg-approve quality."
fi
[ -z "$CHECKED" ] && exit 0

# Commits the target branch already has came in by a merge — not this task's to check.
NOT_TARGET=""
TARGET_REF=$("$PY" "$SCRIPTS/cg_session.py" target-ref 2>/dev/null) && NOT_TARGET="--not $TARGET_REF"
# A merge counts only for what its author changed while resolving it (--remerge-diff, git
# 2.36+); older git cannot tell that apart, so merges are skipped there.
MERGES="--no-merges"
git log -1 --remerge-diff --format= >/dev/null 2>&1 && MERGES="--remerge-diff"

for TIP in $OWN_TIPS; do
  if ! git merge-base --is-ancestor "$CHECKED" "$TIP" 2>/dev/null; then
    block "the last checked commit ($CHECKED) is not in what is being delivered (amend, rebase, reset, or another commit)." \
          "Treat it as rework: write REWORK and run the delta check against the target branch (skill cg-rework)."
  fi
  UNCHECKED=$(git log $MERGES --format= --name-only "$CHECKED..$TIP" $NOT_TARGET 2>/dev/null | grep -v '^$' | grep -v '^\.ai/' | sort -u)
  if [ -n "$UNCHECKED" ]; then
    if [ "$STATE" = QUALITY_REVIEWED ]; then
      block "commits after the independent review change: $(echo $UNCHECKED | cut -c1-200)" \
            "The PR/MR does not exist yet: run the independent review again on the new commits (skill cg-phase-4, §5) — it rewrites checked-sha — then Phase 5."
    fi
    block "commits after the last check change: $(echo $UNCHECKED | cut -c1-200)" \
          "That is rework: write REWORK with the reason, run the delta check (skill cg-rework), then push."
  fi
done

exit 0
