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
# a push or a PR/MR creation leaves at once, before Python is started.
INPUT=$(cat 2>/dev/null || echo "")
case "$INPUT" in *push*|*" create"*|*"pr new"*|*"mr new"*) ;; *) exit 0 ;; esac

# One line per landing (see cg_cmd.py): `ref <dest> <source>`, `mr <target>`, `base <branch> <head>`.
# The Windows Store stub `python3` exists but does not run, so a failed run falls back to
# `python`. Exits 0, 1 and 3 come from the parser; anything else means no usable Python.
SCRIPTS="$(cd "$(dirname "$0")" && pwd)/../scripts"
for PY in python3 python; do
  LANDINGS=$(printf '%s' "$INPUT" | "$PY" "$SCRIPTS/cg_cmd.py" 2>/dev/null)
  RC=$?
  case $RC in 0|1|3) break ;; esac
done
case $RC in
  0) ;;
  1) exit 0 ;;
  3) echo "codegate: this command looks like a push or a PR/MR creation but cannot be parsed (unbalanced quotes?). Run it as a plain command." >&2; exit 2 ;;
  *)
    # Hold back only what starts a command as a push or a PR/MR creation.
    START='("command": *"|;|&|\||\(|\\n)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|(timeout|env|nice|command|exec)[[:space:]]+([0-9][^[:space:]]*[[:space:]]+)?)*([^[:space:]"]*/)?'
    if printf '%s' "$INPUT" | grep -qE "${START}git(\.exe)?([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+push([^[:alnum:]_-]|\$)|${START}(gh|glab)(\.exe)?[[:space:]]+(pr|mr)[[:space:]]+(create|new)"; then
      echo "codegate: Python 3 not found (python3 or python), or $SCRIPTS/cg_cmd.py failed — this hook cannot check the push or PR/MR." >&2
      exit 2
    fi
    exit 0
    ;;
esac

# Like the other hooks: the checkout the call runs in is the `cwd` the hook is given.
CWD=$("$PY" -c "import json,sys; print(json.load(sys.stdin).get('cwd') or '')" <<< "$INPUT" 2>/dev/null)
[ -n "$CWD" ] && cd "$CWD" 2>/dev/null
# `cd DIR && git push`, `git -C DIR push`: the landings belong to the checkout in DIR.
DIR=$(printf '%s\n' "$LANDINGS" | sed -n 's/^dir //p' | head -1)
case "$DIR" in
  "") ;;
  @unknown)
    echo "codegate: this command pushes or opens a PR/MR from a directory given by a variable, or from more than one checkout. Run it from one checkout, with the path written out (cd /path/to/checkout && ...)." >&2
    exit 2 ;;
  *) cd "$DIR" 2>/dev/null || { echo "codegate: no such directory: $DIR" >&2; exit 2; } ;;
esac
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 2
# The markers are the user's one-shot approvals. Only a call that goes through uses them up:
# one blocked by the second gate does not make the user approve the first one again.
CONSUME=""
trap 'rc=$?; [ $rc -eq 0 ] && [ -n "$CONSUME" ] && rm -f $CONSUME; exit $rc' EXIT

# The branch worked on; during a rebase (detached HEAD), the branch being rebased.
CURRENT_BRANCH=$("$PY" "$SCRIPTS/cg_session.py" current-branch 2>/dev/null)
here() { [ "$1" = "HEAD" ] && echo "$CURRENT_BRANCH" || echo "$1"; }

# The session whose branch this call delivers — a pushed destination or a PR/MR head — and only
# then the checked-out branch's: `git push origin feat/x` from another branch delivers feat/x.
SESSION_BRANCH=""
for cand in $(printf '%s\n' "$LANDINGS" | awk '$1 == "ref" { print $2 } $1 == "base" { print $3 }') HEAD; do
  cand=$(here "$cand")
  case "$cand" in ""|@*) continue ;; esac
  SESSION_BRANCH=$("$PY" "$SCRIPTS/cg_session.py" branch --branch "$cand" 2>/dev/null) && break
done
if [ -n "$SESSION_BRANCH" ]; then
  SESSION_DIR=$("$PY" "$SCRIPTS/cg_session.py" dir --branch "$SESSION_BRANCH" 2>/dev/null)
else
  SESSION_DIR=$("$PY" "$SCRIPTS/cg_session.py" dir 2>/dev/null)  # an older session that names no branch
fi
SESSION_TARGET=""
if [ -n "$SESSION_DIR" ]; then
  SESSION_DIR="$ROOT/$SESSION_DIR"
  SESSION_TARGET=$(cat "$SESSION_DIR/target-branch" 2>/dev/null | tr -d '[:space:]')
fi
BASE_OPTION=$(bash "$SCRIPTS/cg-option.sh" base_branch "" 2>/dev/null | tr -d '[:space:]')

# A direct push also must not land on the branch tasks merge into (the task's target, the
# project's base): that is where review happens. A PR/MR into them is the normal path.
protected_ref() {
  case "$1" in main|master|release*|@all|@unknown) return 0 ;; esac
  [ -n "$1" ] && { [ "$1" = "$SESSION_TARGET" ] || [ "$1" = "$BASE_OPTION" ]; }
}
protected_pr() { case "$1" in main|master|release*|@unknown) return 0 ;; esac; return 1; }

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
REF_PROTECTED=""
PR_PROTECTED=""
PR_HEAD=""
OWN_TIPS=""
OWN=""
ALL_REFS_OWN=1
while read -r kind a b; do
  [ "$kind" = "ref" ] || continue
  dest=$(here "$a")
  [ -n "$SESSION_BRANCH" ] && [ "$dest" = "$SESSION_BRANCH" ] || ALL_REFS_OWN=""
  protected_ref "$dest" && PROTECTED="$PROTECTED $dest" && REF_PROTECTED="$REF_PROTECTED $dest"
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
      head=$(here "$(printf '%s\n' "$LANDINGS" | awk '$1 == "ref" { print $2; exit }')")
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
  protected_pr "$t" && PROTECTED="$PROTECTED $t" && PR_PROTECTED="$PR_PROTECTED $t" && PR_HEAD="$head"
done <<< "$LANDINGS"

# --- Gate 1: protected landings ---
PROTECTED=$(printf '%s\n' $PROTECTED | sort -u | tr '\n' ' ')
COUNT=$(echo $PROTECTED | wc -w | tr -d ' ')
if [ "$COUNT" -gt 1 ]; then
  echo "Blocked: this call lands on several protected branches ($PROTECTED). One approval covers one landing — split the command." >&2
  exit 2
fi
if [ "$COUNT" -eq 1 ]; then
  CHECK=$(echo $PROTECTED)
  INTO="${SESSION_TARGET:-$BASE_OPTION}"
  if [ -f .ai/protected-target-allowed ]; then
    CONSUME=".ai/protected-target-allowed"
  elif [ "$CHECK" = "@unknown" ]; then
    echo "Blocked: the branch is named by a variable, so it cannot be checked. Write the branch name out and re-run." >&2
    exit 2
  else
    KIND=push
    case " $PR_PROTECTED " in *" $CHECK "*) KIND=pr ;; esac
    case " $REF_PROTECTED " in *" $CHECK "*) KIND=push ;; esac  # it also lands there directly
    [ "$CHECK" = "@all" ] && KIND=all
    WAY=""
    # A closed task is no way out: recording its branch or target would open a PR/MR its gate
    # never checked. Only an open one is advised to record what it lacks.
    CLOSED=""
    case "$(cat "$SESSION_DIR/state" 2>/dev/null | tr -d '[:space:]')" in MERGED|ABANDONED) CLOSED=1 ;; esac
    # The branch the advice is about: the PR/MR's head, else the one worked on. A protected
    # branch is never a task's own: binding a task to it would only lead to the next refusal.
    WORK="$CURRENT_BRANCH"
    [ "$KIND" = pr ] && WORK="$PR_HEAD"
    case "$WORK" in @*) WORK="" ;; esac
    [ -n "$WORK" ] && protected_ref "$WORK" && WORK=""
    # A task without a recorded target opens no PR/MR into a protected base: it records one first.
    NEEDS_TARGET=""
    [ -z "$SESSION_TARGET" ] && { [ -z "$INTO" ] || protected_pr "$INTO"; } && NEEDS_TARGET=1
    NO_TARGET=""
    [ -z "$CLOSED" ] && [ -n "$SESSION_BRANCH" ] && [ -n "$NEEDS_TARGET" ] && \
      { [ "$KIND" != pr ] || [ "$PR_HEAD" = "$SESSION_BRANCH" ]; } && NO_TARGET=1
    UNBOUND=""
    [ -z "$CLOSED" ] && [ -z "$SESSION_BRANCH" ] && [ -n "$SESSION_DIR" ] && [ -n "$WORK" ] && UNBOUND=1
    RECORD="  - write the task's target to $SESSION_DIR/target-branch, then open its PR/MR, or"$'\n'
    AND_TARGET=""
    [ -n "$NEEDS_TARGET" ] && AND_TARGET=" and the task's target to $SESSION_DIR/target-branch"
    BIND="  - write $WORK to $SESSION_DIR/branch$AND_TARGET, then open its PR/MR, or"$'\n'
    START="  - start a task for this work, or"$'\n'
    case "$KIND" in
      all)
        WHAT="a push of every branch (--all / --mirror), protected ones among them."
        WHY="Landing on a protected branch bypasses review."
        WAY="  - push only the branch you mean, or"$'\n' ;;
      pr)
        WHAT="a PR/MR into '$CHECK', a protected branch."
        if [ -n "$CLOSED" ]; then
          WHY="The task found here is closed."
          WAY="$START"
        elif [ -n "$UNBOUND" ]; then
          WHY="The task found here names no branch."
          WAY="$BIND"
        elif [ -z "$SESSION_BRANCH" ]; then
          WHY="Only the branch of a task that targets it may open one; this branch has no task."
          WAY="$START"
        elif [ -n "$NO_TARGET" ]; then
          WHY="The task on this branch has no target branch recorded."
          WAY="$RECORD"
        elif [ -n "$INTO" ] && [ "$INTO" != "$CHECK" ]; then
          WHY="A task opens its PR/MR into its own target branch."
          WAY="  - open it from the task's branch into $INTO, or"$'\n'
        else
          WHY="Only the branch of the task that targets it may open one."
          WAY="  - open it from the task's branch $SESSION_BRANCH, or"$'\n'
        fi ;;
      push)
        WHAT="a direct push to '$CHECK', a protected branch."
        WHY="Landing on it bypasses review."
        { [ "$CHECK" = "$SESSION_TARGET" ] || [ "$CHECK" = "$BASE_OPTION" ]; } && \
          WHY="Tasks merge into it through a PR/MR; landing on it directly bypasses review."
        if [ -n "$CLOSED" ]; then
          WAY="$START"
        elif [ -n "$NO_TARGET" ]; then
          WAY="$RECORD"
        elif [ -n "$SESSION_BRANCH" ]; then
          WAY="  - push the task's branch and open a PR/MR${INTO:+ into $INTO}, or"$'\n'
        elif [ -n "$UNBOUND" ]; then
          WAY="$BIND"
        else
          WAY="  - start a task for this work; its branch opens the PR/MR, or"$'\n'
        fi ;;
    esac
    printf 'Blocked: %s\n%s\n\n%s  - if you really mean it, approve once:\n      touch %s/.ai/protected-target-allowed\n    then re-run the command. The marker is one-shot.\n' \
      "$WHAT" "$WHY" "$WAY" "$ROOT" >&2
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
    echo "Only if the user explicitly wants this unchecked: touch $ROOT/.ai/push-unchecked-allowed"
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
  MERGED|ABANDONED)
    if [ -n "$SESSION_BRANCH" ]; then
      block "the task on this branch is closed." \
            "Start a new task for this work (Phase 0); its own branch carries it."
    fi
    ;;
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
    QUALITY_REVIEWED)
      block "no checked commit is recorded (checked-sha) — Phase 4 has not concluded." \
            "Finish Phase 4 (skill cg-phase-4): the gate, then the independent review, which writes checked-sha."
      ;;
    PR_CREATED|PR_UPDATED)
      block "no checked commit is recorded (checked-sha) for this PR/MR." \
            "Treat the change as rework: write REWORK and run the delta check (skill cg-rework); it writes checked-sha."
      ;;
  esac
elif [ -z "$CHECKED" ] && [ "$STATE" = QUALITY_REVIEWED ] && grep -qiE 'verdict[^a-z]*FAIL' "$SESSION_DIR/QUALITY_REPORT.md" 2>/dev/null; then
  block "the quality gate verdict is FAIL." \
        "Fix the FAIL items and re-run the gate on the fixes (skill cg-phase-4), or the user overrides with /cg-approve quality."
fi
[ -z "$CHECKED" ] && exit 0

# Commits the target branch already has came in by a merge — not this task's to check.
NOT_TARGET=""
TARGET_REF=$("$PY" "$SCRIPTS/cg_session.py" target-ref ${SESSION_BRANCH:+--branch "$SESSION_BRANCH"} 2>/dev/null) && NOT_TARGET="--not $TARGET_REF"
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
