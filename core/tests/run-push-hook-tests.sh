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
check "MR push options from a feature branch"     feat/x "git push -u -o merge_request.create -o merge_request.target=main -o merge_request.remove_source_branch origin HEAD" 0
check "MR push options from main are blocked"     main   "git push -o merge_request.create -o merge_request.target=dev origin HEAD" 2
check "--push-option value is not a refspec"      feat/x "git push --push-option merge_request.create origin feat/x" 0

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
