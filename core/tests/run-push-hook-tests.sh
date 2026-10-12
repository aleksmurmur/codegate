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
session IMPLEMENTING feat/other
check "another task's branch is not held back"    feat/x "git push -u origin feat/x"  0
session IMPLEMENTING ""
check "session without a recorded branch blocks"  feat/x "git push -u origin feat/x"  2
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
