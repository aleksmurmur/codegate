#!/bin/bash
# Tests for pre-push.sh gate 1 — which branch a `git push` command lands on.
#
# GitLab merge requests are created with `git push -o merge_request.create -o
# merge_request.target=<b> origin HEAD`. The option values are not refspecs, and
# `HEAD` is the current branch: before this was handled, `git push origin HEAD`
# from main slipped past the protected-branch gate.
#
#   core/tests/run-push-hook-tests.sh          (from the cg-core checkout)
#
# Exits 0 if all assertions hold, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(cd "$SCRIPT_DIR/../shared/.claude/hooks" && pwd)/pre-push.sh"
PASS=0
FAIL=0

[ -f "$HOOK" ] || { echo "ERROR: pre-push.sh not found at $HOOK"; exit 2; }

REPO=$(mktemp -d)
trap 'rm -rf "$REPO"' EXIT
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# check <name> <branch> <command> <want_exit>
check() {
    local name="$1" branch="$2" cmd="$3" want="$4" got
    git -C "$REPO" checkout -q -B "$branch"
    rm -f "$REPO/.ai/protected-target-allowed"
    printf '{"tool_input":{"command":"%s"}}' "$cmd" | ( cd "$REPO" && bash "$HOOK" >/dev/null 2>&1 )
    got=$?
    if [ "$got" = "$want" ]; then
        echo "PASS  $name"; PASS=$((PASS + 1))
    else
        echo "FAIL  $name  (want exit=$want, got exit=$got)"; FAIL=$((FAIL + 1))
    fi
}

check "feature branch, plain push"                feat/x "git push -u origin feat/x"  0
check "explicit push to main is blocked"          feat/x "git push origin main"       2
check "refspec onto main is blocked"              feat/x "git push origin HEAD:main"  2
check "HEAD from main is blocked"                 main   "git push origin HEAD"       2
check "HEAD from a feature branch passes"         feat/x "git push origin HEAD"       0
check "MR push options from a feature branch"     feat/x "git push -u -o merge_request.create -o merge_request.target=dev -o merge_request.remove_source_branch origin HEAD" 0
check "MR push options from main are blocked"     main   "git push -o merge_request.create -o merge_request.target=dev origin HEAD" 2
check "--push-option value is not a refspec"      feat/x "git push --push-option merge_request.remove_source_branch origin feat/x" 0
check "MR into main via push options is blocked"  feat/x "git push -o merge_request.create -o merge_request.target=main origin HEAD" 2
check "MR into master via --push-option= blocked" feat/x "git push --push-option=merge_request.target=master origin HEAD" 2
check "MR into dev via push options passes"       feat/x "git push -o merge_request.create -o merge_request.target=dev origin HEAD" 0
check "quoted title with spaces is one value"     feat/x "git push -o merge_request.create -o merge_request.target=dev -o merge_request.title=\\\"Fix the main page\\\" origin HEAD" 0
check "quoted title does not hide HEAD on main"   main   "git push -o merge_request.title=\\\"two words\\\" origin HEAD" 2

check "full ref onto main is blocked"             feat/x "git push origin HEAD:refs/heads/main"  2

# says <name> <branch> <command> <text> [absent] — what the block message says (or must not)
says() {
    local out
    git -C "$REPO" checkout -q -B "$2"
    rm -f "$REPO/.ai/protected-target-allowed"
    out=$(printf '{"tool_input":{"command":"%s"}}' "$3" | ( cd "$REPO" && bash "$HOOK" 2>&1 >/dev/null ))
    case "$out" in *"$4"*) found=1 ;; *) found=0 ;; esac
    if [ "$found" = "$([ -n "${5:-}" ] && echo 0 || echo 1)" ]; then
        echo "PASS  $1"; PASS=$((PASS + 1))
    else
        echo "FAIL  $1  (message: $out)"; FAIL=$((FAIL + 1))
    fi
}
says "a direct push is called one"                feat/x "git push origin main" "a direct push to 'main'"
says "a PR/MR is called one"                      feat/x "git push -o merge_request.create -o merge_request.target=main origin HEAD" "a PR/MR into 'main'"
says "a PR/MR that also pushes main is a push"    feat/x "git push -o merge_request.create -o merge_request.target=main origin main" "a direct push to 'main'"
says "no target known: no advice to repeat it"    feat/x "git push -o merge_request.create -o merge_request.target=main origin HEAD" "open it from" absent
says "no task: the way out is a task"             feat/x "git push origin main" "start a task"
says "no task: a refused PR/MR points to a task"  feat/x "git push -o merge_request.create -o merge_request.target=main origin HEAD" "start a task"
says "no task: no 'task's branch' for --all"      feat/x "git push --all origin" "the task's branch" absent
mkdir -p "$REPO/.ai/sessions/s0" && echo feat/x > "$REPO/.ai/sessions/s0/branch" && echo IMPLEMENTING > "$REPO/.ai/sessions/s0/state"
says "a task without a target: record it (PR/MR)" feat/x "gh pr create --base main --head feat/x" "s0/target-branch"
says "a task without a target: record it (push)"  feat/x "git push origin HEAD:main" "s0/target-branch"
says "another branch's PR/MR: not this task's target" feat/z "gh pr create --base main --head feat/w" "s0/target-branch" absent
mkdir -p "$REPO/.ai/sessions/s7" && echo feat/z > "$REPO/.ai/sessions/s7/branch" && echo IMPLEMENTING > "$REPO/.ai/sessions/s7/state"
says "...nor told to open it 'into' nothing"      feat/z "gh pr create --base main --head feat/w" "into ," absent
says "...but from the task's branch"              feat/z "gh pr create --base main --head feat/w" "from the task's branch feat/z"
says "...and not asked for its target"            feat/z "gh pr create --base main --head feat/w" "s7/target-branch" absent
rm -rf "$REPO/.ai/sessions/s7" "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/codegate/sessions/s7"
echo MERGED > "$REPO/.ai/sessions/s0/state"
says "a closed task is not told to record a target" feat/x "gh pr create --base main --head feat/x" "start a task"
echo main > "$REPO/.ai/sessions/s0/target-branch"
check "a closed task's branch opens no PR/MR"     feat/x "gh pr create --base main --head feat/x" 2
check "...nor is pushed"                          feat/x "git push origin feat/x" 2
check "...but is deleted after the merge"         main   "git push origin --delete feat/x" 0
check "...also with -d"                           main   "git push -d origin feat/x" 0
echo ABANDONED > "$REPO/.ai/sessions/s0/state"
check "an abandoned task's branch is not pushed"  feat/x "git push origin feat/x" 2
touch "$REPO/.ai/push-unchecked-allowed"
check "...unless the user approves once"          feat/x "git push origin feat/x" 0
check "...and only once"                          feat/x "git push origin feat/x" 2
says "a closed task's branch: start a new task"   feat/x "gh pr create --base main --head feat/x" "Start a new task"
rm -rf "$REPO/.ai/sessions/s0" "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/codegate/sessions/s0"
mkdir -p "$REPO/.ai/sessions/s9" && echo IMPLEMENTING > "$REPO/.ai/sessions/s9/state" && echo s9 > "$REPO/.ai/current-session"
says "an open session naming no branch: bind it"  feat/x "gh pr create --base main --head feat/x" "write feat/x to"
says "binding it asks for the target too"         feat/x "gh pr create --base main --head feat/x" "s9/target-branch"
says "never bound to a protected branch"          main   "git push origin HEAD" "s9/branch" absent
says "on a protected branch: start a task"        main   "git push origin HEAD" "start a task"
echo MERGED > "$REPO/.ai/sessions/s9/state"
says "a closed one is no way out"                 feat/x "gh pr create --base main --head feat/x" "start a task"
rm -rf "$REPO/.ai/sessions/s9" "$REPO/.ai/current-session" "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/codegate/sessions/s9"
says "a variable branch asks for the name"        feat/x 'git push origin \"$B\"' "Write the branch name out"
says "--all names every branch"                   feat/x "git push --all origin" "every branch"
check "forced refspec onto main is blocked"       feat/x "git push origin +main"                 2
check "any of several refspecs onto main blocked" feat/x "git push origin feat/x:main feat/x:other" 2
check "several refspecs off main pass"            feat/x "git push origin feat/x feat/x:other"   0
check "unexpanded MR target is treated protected" feat/x "git push -o merge_request.create -o merge_request.target=\$TARGET origin HEAD" 2
check "MR create without target, default main"    feat/x "git push -o merge_request.create origin HEAD" 2
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/dev
check "MR create without target, default dev"     feat/x "git push -o merge_request.create origin HEAD" 0

# ── gate 2: a session that has not passed the quality gate holds back ITS branch ────────
# Claude Code blocks a tool call only on exit 2; the gate used to exit 1 and never blocked.
echo ""
echo "-- gate 2: active session --"
mkdir -p "$REPO/.ai/sessions/s1" "$REPO/.claude/scripts"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../shared/.claude/scripts" && pwd)"
cp "$SCRIPTS_DIR/cg_session.py" "$REPO/.claude/scripts/"
echo "s1" > "$REPO/.ai/current-session"
session() { echo "$1" > "$REPO/.ai/sessions/s1/state"; if [ -n "$2" ]; then echo "$2" > "$REPO/.ai/sessions/s1/branch"; else rm -f "$REPO/.ai/sessions/s1/branch"; fi; }

session IMPLEMENTING feat/x
check "own branch before the gate is blocked"     feat/x "git push -u origin feat/x"  2
ERR=$(printf '{"tool_input":{"command":"git push -u origin feat/x"}}' | ( cd "$REPO" && bash "$HOOK" 2>&1 >/dev/null ))
if [ -n "$ERR" ]; then echo "PASS  gate 2 reason goes to stderr"; PASS=$((PASS + 1))
else echo "FAIL  gate 2 reason goes to stderr  (stderr was empty)"; FAIL=$((FAIL + 1)); fi
session QUALITY_REVIEWED feat/x
git -C "$REPO" rev-parse feat/x > "$REPO/.ai/sessions/s1/checked-sha"
check "own branch after the gate passes"          feat/x "git push -u origin feat/x"  0
rm -f "$REPO/.ai/sessions/s1/checked-sha"
session IMPLEMENTING feat/x
check "a commit mentioning push is not a push"    feat/x "git commit -m 'push it later'"  0
check "a grep for push is not a push"            feat/x "grep -rn push .claude"  0
check "push after && is still checked"           feat/x "git add a.kt && git push -u origin feat/x"  2
check "git -C dir push is still checked"         feat/x "git -C . push -u origin feat/x"  2
session IMPLEMENTING feat/other
check "another task's branch is not held back"    feat/x "git push -u origin feat/x"  0
session IMPLEMENTING ""
check "session without a recorded branch blocks"  feat/x "git push -u origin feat/x"  2
session IMPLEMENTING feat/x
echo main > "$REPO/.ai/sessions/s1/target-branch"
git -C "$REPO" checkout -q -B feat/x && git -C "$REPO" checkout -q --detach
mkdir -p "$REPO/.git/rebase-merge" && echo refs/heads/feat/x > "$REPO/.git/rebase-merge/head-name"
out=$(printf '{"tool_input":{"command":"git push origin HEAD:main"}}' | ( cd "$REPO" && bash "$HOOK" 2>&1 >/dev/null ))
case "$out" in *"s1/branch"*) echo "FAIL  mid-rebase the task is still found  (message: $out)"; FAIL=$((FAIL + 1)) ;;
  *"push the task's branch"*) echo "PASS  mid-rebase the task is still found"; PASS=$((PASS + 1)) ;;
  *) echo "FAIL  mid-rebase the task is still found  (message: $out)"; FAIL=$((FAIL + 1)) ;; esac
out=$(printf '{"tool_input":{"command":"gh pr create --base main"}}' | ( cd "$REPO" && bash "$HOOK" 2>&1 >/dev/null ))
case "$out" in *"open it from"*) echo "FAIL  mid-rebase a PR/MR's head is the rebased branch  (message: $out)"; FAIL=$((FAIL + 1)) ;;
  *) echo "PASS  mid-rebase a PR/MR's head is the rebased branch"; PASS=$((PASS + 1)) ;; esac
rm -rf "$REPO/.git/rebase-merge" "$REPO/.ai/sessions/s1/target-branch"
rm -rf "$REPO/.ai/sessions" "$REPO/.ai/current-session"

# ── after the gate: rework and commits made after the last check ────────────────────────
echo ""
echo "-- after the gate: checked-sha --"
mkdir -p "$REPO/.ai/sessions/s1"
gr() { git -C "$REPO" -c user.email=t@t -c user.name=t "$@"; }
git -C "$REPO" checkout -q -B feat/x
echo feat/x > "$REPO/.ai/sessions/s1/branch"
echo main > "$REPO/.ai/sessions/s1/target-branch"
echo PR_CREATED > "$REPO/.ai/sessions/s1/state"
gr commit -q --allow-empty -m gated
gr rev-parse HEAD > "$REPO/.ai/sessions/s1/checked-sha"
push_check() {
    local name="$1" want="$2" got
    rm -f "$REPO/.ai/protected-target-allowed"
    printf '{"tool_input":{"command":"git push origin feat/x"}}' | ( cd "$REPO" && bash "$HOOK" >/dev/null 2>&1 )
    got=$?
    if [ "$got" = "$want" ]; then echo "PASS  $name"; PASS=$((PASS + 1))
    else echo "FAIL  $name  (want exit=$want, got exit=$got)"; FAIL=$((FAIL + 1)); fi
}
push_check "nothing after the check: push passes" 0
mkdir -p "$REPO/.ai/tech-debt" && echo note > "$REPO/.ai/tech-debt/n.md"
gr add -f .ai/tech-debt/n.md && gr commit -q -m "docs: tech debt"
push_check "a commit touching only .ai/ does not count" 0
echo code > "$REPO/fix.kt" && gr add fix.kt && gr commit -q -m "fix: qa"
push_check "an unchecked code commit after the MR blocks" 2
echo REWORK > "$REPO/.ai/sessions/s1/state"
push_check "rework before its delta check blocks" 2
gr rev-parse HEAD > "$REPO/.ai/sessions/s1/checked-sha"
echo PR_UPDATED > "$REPO/.ai/sessions/s1/state"
push_check "checked rework passes" 0
git -C "$REPO" checkout -q main
echo other > "$REPO/main-change.txt" && gr add main-change.txt && gr commit -q -m "on main"
git -C "$REPO" checkout -q feat/x
gr merge -q --no-edit main
push_check "a merge of the target branch does not count" 0
echo amended > "$REPO/fix.kt" && gr commit -q -a --amend --no-edit
gr rev-parse HEAD~1 >/dev/null
echo deadbeefdeadbeefdeadbeefdeadbeefdeadbeef > "$REPO/.ai/sessions/s1/checked-sha"
push_check "a checked commit gone from the branch blocks" 2
rm -f "$REPO/.ai/sessions/s1/checked-sha"
echo QUALITY_REVIEWED > "$REPO/.ai/sessions/s1/state"
printf '# Quality report\n**Verdict**: FAIL\n' > "$REPO/.ai/sessions/s1/QUALITY_REPORT.md"
push_check "a FAIL verdict blocks the push" 2
echo PR_CREATED > "$REPO/.ai/sessions/s1/state"
rm -f "$REPO/.ai/sessions/s1/checked-sha" "$REPO/.ai/sessions/s1/QUALITY_REPORT.md"
push_check "a branch-bound session without checked-sha blocks" 2
touch "$REPO/.ai/push-unchecked-allowed"
printf '{"tool_input":{"command":"git push origin feat/x"}}' | ( cd "$REPO" && bash "$HOOK" >/dev/null 2>&1 ); got=$?
if [ "$got" = 0 ] && [ ! -f "$REPO/.ai/push-unchecked-allowed" ]; then echo "PASS  the user's one-shot override passes once"; PASS=$((PASS + 1))
else echo "FAIL  the user's one-shot override passes once (exit=$got)"; FAIL=$((FAIL + 1)); fi
push_check "and only once" 2

gr rev-parse HEAD > "$REPO/.ai/sessions/s1/checked-sha"
echo PR_UPDATED > "$REPO/.ai/sessions/s1/state"
git -C "$REPO" checkout -q main
echo main-version > "$REPO/fix.kt" && gr add fix.kt && gr commit -q -m "main touches fix.kt"
git -C "$REPO" checkout -q feat/x
gr merge -q main >/dev/null 2>&1
echo resolved > "$REPO/fix.kt" && gr add fix.kt && gr commit -q -m "merge main"
if git -C "$REPO" log -1 --remerge-diff --format= >/dev/null 2>&1; then
  push_check "a merge whose conflict resolution changes code blocks" 2
fi

# ── how the command is read: every hook call is a Bash call, so the parse decides ────────
echo ""
echo "-- command parsing --"
gr rev-parse feat/x > "$REPO/.ai/sessions/s1/checked-sha"
session IMPLEMENTING feat/x
check "subshell push to main is blocked"           feat/x "(git push origin main)"         2
check "push after && without spaces"               feat/x "cd .&&git push origin main"     2
check "push inside bash -c"                        feat/x "bash -c 'git push origin main'" 2
check "git.exe push"                               feat/x "git.exe push origin main"       2
check "a later segment is not a refspec"           dev    "git push origin dev && git checkout main" 0
check "variable destination is the current branch" feat/x 'git push -u origin \"$(git branch --show-current)\"' 2
check "variable destination via assignment"        feat/x 'B=feat/x; git push origin $B'  2

touch "$REPO/.ai/protected-target-allowed"
printf '{"tool_input":{"command":"git push origin feat/x:main feat/x"}}' | ( cd "$REPO" && bash "$HOOK" >/dev/null 2>&1 ); got=$?
if [ "$got" = 2 ] && [ -f "$REPO/.ai/protected-target-allowed" ]; then echo "PASS  a push blocked by gate 2 keeps the gate 1 approval"; PASS=$((PASS + 1))
else echo "FAIL  a push blocked by gate 2 keeps the gate 1 approval (exit=$got)"; FAIL=$((FAIL + 1)); fi
rm -f "$REPO/.ai/protected-target-allowed"

session PR_CREATED feat/x
echo main > "$REPO/.ai/sessions/s1/target-branch"
check "MR into the task's own target needs no marker" feat/x "git push -o merge_request.create -o merge_request.target=main origin HEAD" 0
check "a direct push to that target is still blocked" feat/x "git push origin HEAD:main" 2

check "git stash push is not a push"               main   "git stash push"                 0

# ── pre-pr.sh ──────────────────────────────────────────────────────────────────────────
echo ""
echo "-- pre-pr --"
PRHOOK="$HOOK"  # pre-push.sh checks PR/MR creation too
pr_check() {
    local name="$1" cmd="$2" want="$3" got
    rm -f "$REPO/.ai/protected-target-allowed"
    printf '{"tool_input":{"command":"%s"}}' "$cmd" | ( cd "$REPO" && bash "$PRHOOK" >/dev/null 2>&1 )
    got=$?
    if [ "$got" = "$want" ]; then echo "PASS  $name"; PASS=$((PASS + 1))
    else echo "FAIL  $name  (want exit=$want, got exit=$got)"; FAIL=$((FAIL + 1)); fi
}
git -C "$REPO" checkout -q feat/x
echo dev > "$REPO/.ai/sessions/s1/target-branch"
pr_check "quoted protected base is blocked"  'gh pr create --base \"main\"'      2
pr_check "base dev passes"                   'gh pr create --base dev'           0
pr_check "glab -b is the target branch"      'glab mr create -b dev'             0
pr_check "a variable base is blocked"        'gh pr create --base \"$TARGET\"'   2
pr_check "an echo of the command is no PR"   'echo gh pr create --base main'     0
echo main > "$REPO/.ai/sessions/s1/target-branch"
pr_check "the task's own target passes"      'gh pr create --base main'          0

# ── sixth audit: shell forms, the target exemption, the pushed commit ───────────────────
echo ""
echo "-- shell forms and deliveries --"
rm -f "$REPO/.ai/sessions/s1/target-branch"
check "push inside if/then"                  feat/x 'if true; then git push origin main; fi'   2
check "push inside a for loop"               feat/x 'for b in x; do git push origin main; done' 2
check "push behind timeout"                  feat/x 'timeout 60 git push origin main'          2
check "push --all"                           feat/x 'git push --all origin'                    2
check "push after a comment line"            feat/x 'echo hi # it is\ngit push origin main'    2
check "a comment mentioning push is ignored" main   'ls # then git push origin main'           0
check "a heredoc body is not a command"      main   'cat > n.md <<EOF\ngit push origin main\nEOF' 0
pr_check "gh pr new is a PR creation"        'gh pr new --base main'                           2

echo main > "$REPO/.ai/sessions/s1/target-branch"
session IMPLEMENTING feat/x
check "MR to the target from another branch name" feat/x "git push -o merge_request.create -o merge_request.target=main origin HEAD:feat/x-copy" 2
pr_check "PR to the target from another head"     'gh pr create --base main --head feat/x-copy'  2
pr_check "the task's own PR before the gate"      'gh pr create --base main'                      2

session QUALITY_REVIEWED feat/x
gr rev-parse feat/x > "$REPO/.ai/sessions/s1/checked-sha"
git -C "$REPO" checkout -q --detach
echo detached > "$REPO/detached.kt" && gr add detached.kt && gr commit -q -m "unchecked on a detached HEAD"
printf '{"tool_input":{"command":"git push origin HEAD:feat/x"}}' | ( cd "$REPO" && bash "$HOOK" >/dev/null 2>&1 ); got=$?
if [ "$got" = 2 ]; then echo "PASS  the pushed commit is checked, not the branch tip"; PASS=$((PASS + 1))
else echo "FAIL  the pushed commit is checked, not the branch tip (exit=$got)"; FAIL=$((FAIL + 1)); fi
git -C "$REPO" checkout -q feat/x
gr merge -q --ff-only "HEAD@{1}" 2>/dev/null || git -C "$REPO" reset -q --hard "HEAD@{1}"
ERR=$(printf '{"tool_input":{"command":"git push origin feat/x"}}' | ( cd "$REPO" && bash "$HOOK" 2>&1 >/dev/null ))
case "$ERR" in *"independent review again"*) echo "PASS  new commits before the PR/MR go back to the review"; PASS=$((PASS + 1)) ;;
  *) echo "FAIL  new commits before the PR/MR go back to the review ($ERR)"; FAIL=$((FAIL + 1)) ;; esac
gr rev-parse feat/x > "$REPO/.ai/sessions/s1/checked-sha"

rm -f "$REPO/.ai/sessions/s1/target-branch"
touch "$REPO/.ai/protected-target-allowed"
printf '{"tool_input":{"command":"git push origin HEAD:main; git push origin HEAD:master"}}' | ( cd "$REPO" && bash "$HOOK" >/dev/null 2>&1 ); got=$?
if [ "$got" = 2 ]; then echo "PASS  one marker does not cover two protected landings"; PASS=$((PASS + 1))
else echo "FAIL  one marker does not cover two protected landings (exit=$got)"; FAIL=$((FAIL + 1)); fi
rm -f "$REPO/.ai/protected-target-allowed"

# ── seventh audit: the target branch, the pushed branch's session, commands the flow writes ──
echo ""
echo "-- target branch and the pushed branch's session --"
echo dev > "$REPO/.ai/sessions/s1/target-branch"
session IMPLEMENTING feat/x
check "a direct push onto the task's target is blocked" feat/x 'git push origin HEAD:dev'          2
check "a variable destination is blocked"               feat/x 'T=main; git push origin HEAD:$T'   2
check "pushing the task's branch from another branch"   main   'git push -u origin feat/x'         2
pr_check "its PR from another branch"                   'gh pr create --base dev --head feat/x' 2
git -C "$REPO" checkout -q feat/x
session PR_CREATED feat/x
gr rev-parse feat/x > "$REPO/.ai/sessions/s1/checked-sha"
echo main > "$REPO/.ai/sessions/s1/target-branch"
check "pushing tags pushes no branch"                   main   'git push origin --tags'            0
check "Phase 5's push written over several lines"       feat/x 'git push -u -o merge_request.create \\\n  -o merge_request.target=main \\\n  origin HEAD' 0
check "a commit message with an open parenthesis"       feat/x 'git commit -m \"$(cat <<'"'"'EOF'"'"'\nfix: retry the push (see #12\nEOF\n)\"' 0

# ── ninth audit: a push from another checkout is judged by that checkout's task ──────────
echo ""
echo "-- another checkout --"
WT="$REPO/.claude/worktrees/y"
git -C "$REPO" worktree add -q -b feat/y "$WT" feat/x 2>/dev/null
mkdir -p "$WT/.ai/sessions/s2"
echo IMPLEMENTING > "$WT/.ai/sessions/s2/state"; echo feat/y > "$WT/.ai/sessions/s2/branch"; echo main > "$WT/.ai/sessions/s2/target-branch"
WT_ABS=$(cd "$WT" && pwd)
REPO_ABS=$(cd "$REPO" && pwd)
check "cd into an unchecked worktree, then push"      feat/x "cd $WT_ABS && git push -u origin HEAD"   2
check "git -C an unchecked worktree push"             feat/x "git -C $WT_ABS push -u origin HEAD"      2
check "cd into an unchecked worktree, then its PR"    feat/x "cd $WT_ABS && gh pr create --base main"  2
check "cd into a directory held in a variable"        feat/x 'cd $WT && git push'                     2
check "cd into this checkout, then push"              feat/x "cd $REPO_ABS && git push -u origin HEAD" 0
check "pushd into an unchecked worktree, then push"   feat/x "pushd $WT_ABS && git push -u origin HEAD" 2
check "a subshell's cd does not outlive it"           feat/x "(cd $WT_ABS && git log -1) && git push -u origin HEAD" 0
HOME=$(dirname "$REPO_ABS") USERPROFILE=$(dirname "$REPO_ABS") \
check "cd ~/... is the home directory"                feat/x "cd ~/$(basename "$REPO_ABS") && git push -u origin HEAD" 0

# ── without Python only what looks like a push is held back ─────────────────────────────
if ! env PATH=/usr/bin bash -c 'command -v python3 || command -v python' >/dev/null 2>&1; then
    printf '{"tool_input":{"command":"git stash push"},"description":"push it"}' | env PATH=/usr/bin bash "$HOOK" >/dev/null 2>&1; got=$?
    if [ "$got" = 0 ]; then echo "PASS  no Python: an unrelated command passes"; PASS=$((PASS + 1))
    else echo "FAIL  no Python: an unrelated command passes (exit=$got)"; FAIL=$((FAIL + 1)); fi
    printf '{"tool_input":{"command":"git -C . push origin x"}}' | env PATH=/usr/bin bash "$HOOK" >/dev/null 2>&1; got=$?
    if [ "$got" = 2 ]; then echo "PASS  no Python: a push is blocked"; PASS=$((PASS + 1))
    else echo "FAIL  no Python: a push is blocked (exit=$got)"; FAIL=$((FAIL + 1)); fi
    printf '{"tool_input":{"command":"timeout 60 git push origin x"}}' | env PATH=/usr/bin bash "$HOOK" >/dev/null 2>&1; got=$?
    if [ "$got" = 2 ]; then echo "PASS  no Python: a push behind timeout is blocked"; PASS=$((PASS + 1))
    else echo "FAIL  no Python: a push behind timeout is blocked (exit=$got)"; FAIL=$((FAIL + 1)); fi
    printf '{"tool_input":{"command":"echo \\"git push\\""}}' | env PATH=/usr/bin bash "$HOOK" >/dev/null 2>&1; got=$?
    if [ "$got" = 0 ]; then echo "PASS  no Python: an echoed string passes"; PASS=$((PASS + 1))
    else echo "FAIL  no Python: an echoed string passes (exit=$got)"; FAIL=$((FAIL + 1)); fi
    printf '{"tool_input":{"command":"git commit -m \\"docs: explain git push flow\\""}}' | env PATH=/usr/bin bash "$HOOK" >/dev/null 2>&1; got=$?
    if [ "$got" = 0 ]; then echo "PASS  no Python: a commit message mentioning git push passes"; PASS=$((PASS + 1))
    else echo "FAIL  no Python: a commit message mentioning git push passes (exit=$got)"; FAIL=$((FAIL + 1)); fi
fi

SETTINGS="$(dirname "$HOOK")/../settings.json"
if grep -q '"matcher": *"[^"]*(' "$SETTINGS"; then
  echo "FAIL  a hook matcher uses Bash(...) syntax, which never matches"; FAIL=$((FAIL + 1))
else
  echo "PASS  hook matchers name tools only"; PASS=$((PASS + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
