#!/bin/bash
# Tests for post-compact.sh — the SessionStart hook that restores context and notices
# commits the session logged that no branch holds any more.
#
# The notice used to rewrite the session state to PLAN_APPROVED, checked reachability from
# whatever HEAD was checked out, and only ran when `.git` was a directory. In practice it
# fired on every branch switch (0 confirmed rewinds in 32 notices), left sessions with an
# open MR stuck in PLAN_APPROVED, and never ran in a worktree, where `.git` is a file.
#
#   core/tests/run-compact-hook-tests.sh          (from the cg-core checkout)
#
# Exits 0 if all assertions hold, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(cd "$SCRIPT_DIR/../shared/.claude/hooks" && pwd)/post-compact.sh"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../shared/.claude/scripts" && pwd)"
PASS=0
FAIL=0

[ -f "$HOOK" ] || { echo "ERROR: post-compact.sh not found at $HOOK"; exit 2; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
REPO="$ROOT/repo"
git init -q -b main "$REPO"
g() { git -C "$REPO" -c user.email=t@t -c user.name=t "$@"; }
g commit -q --allow-empty -m init

# session <dir> <state> <sha> — a session in <dir> that logged commit <sha>
session() {
    mkdir -p "$1/.ai/sessions/s1" "$1/.claude/scripts"
    cp "$SCRIPTS_DIR/cg_session.py" "$1/.claude/scripts/"
    echo "s1" > "$1/.ai/current-session"
    echo "$2" > "$1/.ai/sessions/s1/state"
    echo "task" > "$1/.ai/sessions/s1/task.md"
    echo "[t] commit: $3 — feat: x" > "$1/.ai/sessions/s1/audit.log"
}
run() { printf '{"cwd":"%s"}' "$1" | bash "$HOOK" 2>/dev/null; }
pass() { echo "PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL + 1)); }

# ── a commit on another branch is not lost: the agent merely switched branches ──────────
g checkout -q -b feat/x
g commit -q --allow-empty -m work
WORK=$(g rev-parse HEAD)
g checkout -q main
session "$REPO" PR_CREATED "$WORK"
OUT=$(run "$REPO")
case "$OUT" in *REWIND*|*"not reachable"*) fail "branch switch is not reported as lost commits" ;; *) pass "branch switch is not reported as lost commits" ;; esac
[ "$(cat "$REPO/.ai/sessions/s1/state")" = "PR_CREATED" ] && pass "state untouched after a branch switch" || fail "state untouched after a branch switch"

# ── a commit no branch holds is reported, and the state is left alone ──────────────────
g checkout -q feat/x
g reset -q --hard HEAD~1
session "$REPO" PR_CREATED "$WORK"
OUT=$(run "$REPO")
case "$OUT" in *"not reachable"*) pass "lost commit is reported" ;; *) fail "lost commit is reported" ;; esac
[ "$(cat "$REPO/.ai/sessions/s1/state")" = "PR_CREATED" ] && pass "state not rewritten" || fail "state not rewritten (now: $(cat "$REPO/.ai/sessions/s1/state"))"

# ── the same check runs in a worktree, where .git is a file ────────────────────────────
WT="$ROOT/wt"
g worktree add -q -b feat/wt "$WT" main
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m wt-work
LOST=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" reset -q --hard HEAD~1
session "$WT" IMPLEMENTING "$LOST"
OUT=$(run "$WT")
case "$OUT" in *"not reachable"*) pass "worktree: lost commit is reported" ;; *) fail "worktree: lost commit is reported" ;; esac

# ── elicitation: an open round and a completed one read differently ─────────────────────
session "$REPO" IDLE "$WORK"
echo "## Round 1" > "$REPO/.ai/sessions/s1/elicitation.md"
OUT=$(run "$REPO")
case "$OUT" in *"round is open"*) pass "open elicitation round" ;; *) fail "open elicitation round" ;; esac
printf '# Design\n## Shape\n' > "$REPO/.ai/sessions/s1/design.md"
OUT=$(run "$REPO")
case "$OUT" in *"critic has not run"*) pass "design draft awaiting critique" ;; *) fail "design draft awaiting critique" ;; esac
printf '## Critique\nNo findings.\n' >> "$REPO/.ai/sessions/s1/design.md"
OUT=$(run "$REPO")
case "$OUT" in *"has not answered it"*) pass "critique awaiting dispositions" ;; *) fail "critique awaiting dispositions" ;; esac
printf '## Critique dispositions\n' >> "$REPO/.ai/sessions/s1/design.md"
OUT=$(run "$REPO")
case "$OUT" in *"round is open"*) pass "after dispositions the round is open again" ;; *) fail "after dispositions the round is open again" ;; esac
echo "- shape" > "$REPO/.ai/sessions/s1/requirements.md"
OUT=$(run "$REPO")
case "$OUT" in *"Elicitation complete"*) pass "completed elicitation" ;; *) fail "completed elicitation" ;; esac
case "$OUT" in *"/cg-approve"*) fail "no approval is asked for" ;; *) pass "no approval is asked for" ;; esac

# ── the short path: proposed, under way, outgrown ──────────────────────────────────────
rm -rf "$REPO/.ai/sessions/s1"
session "$REPO" IDLE "$WORK"
S="$REPO/.ai/sessions/s1"
echo "## Short path" > "$S/short-path.md"
OUT=$(run "$REPO")
case "$OUT" in *"Short path proposed"*) pass "short path waits for the user" ;; *) fail "short path waits for the user" ;; esac
echo short > "$S/path"; echo "# Requirements (short path)" > "$S/requirements.md"; echo IMPLEMENTING > "$S/state"
OUT=$(run "$REPO")
case "$OUT" in *"short path"*"no PLAN.md"*) pass "short path implementation needs no plan" ;; *) fail "short path implementation needs no plan" ;; esac
echo full > "$S/path"; echo IDLE > "$S/state"
OUT=$(run "$REPO")
case "$OUT" in *"Elicitation complete"*) fail "outgrown short path: its requirements are not a finished elicitation" ;; *"after the short path"*) pass "outgrown short path: its requirements are not a finished elicitation" ;; *) fail "outgrown short path: its requirements are not a finished elicitation" ;; esac
printf '## Round 1\n## Elicitation complete\n' > "$S/elicitation.md"
OUT=$(run "$REPO")
case "$OUT" in *"Elicitation complete"*) pass "outgrown short path, elicitation then completed" ;; *) fail "outgrown short path, elicitation then completed" ;; esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
