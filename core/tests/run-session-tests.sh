#!/bin/bash
# Tests for cg_session.py — which task belongs to this checkout — and the two hooks built on
# it: task-context.sh (the line each user message carries) and pre-agent.sh (no elicitation
# or planning without a task on the branch).
#
# The old pointer `.ai/current-session` was one file for the whole repository: parallel
# tasks overwrote it, and sessions vanished with the worktree that held them. A session now
# belongs to a branch, and a copy lives in the shared git directory.
#
#   core/tests/run-session-tests.sh          (from the cg-core checkout)
#
# Exits 0 if all assertions hold, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED="$(cd "$SCRIPT_DIR/../shared/.claude" && pwd)"
PASS=0
FAIL=0
PY=$(command -v python3 || command -v python)

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
REPO="$ROOT/repo"
git init -q -b main "$REPO"
g() { git -C "$REPO" -c user.email=t@t -c user.name=t "$@"; }
install_into() {
    mkdir -p "$1/.claude/scripts" "$1/.claude/hooks"
    cp "$SHARED/scripts/cg_session.py" "$1/.claude/scripts/"
    cp "$SHARED/hooks/task-context.sh" "$SHARED/hooks/pre-agent.sh" "$1/.claude/hooks/"
}
install_into "$REPO"
printf 'codegate_version: x\noptions:\n  base_branch: main\nfiles:\n' > "$REPO/.claude/codegate-installed.yml"
printf '.ai/\n.claude/\n' > "$REPO/.gitignore"
g add .gitignore && g commit -q -m init

# session <dir> <id> <branch> <state> — a session written in checkout <dir>
session() {
    mkdir -p "$1/.ai/sessions/$2"
    [ -n "$3" ] && echo "$3" > "$1/.ai/sessions/$2/branch"
    echo "$4" > "$1/.ai/sessions/$2/state"
    echo "task $2" > "$1/.ai/sessions/$2/task.md"
    echo main > "$1/.ai/sessions/$2/target-branch"
}
cg() { ( cd "$1" && shift && "$PY" .claude/scripts/cg_session.py "$@" 2>/dev/null ); }
is() {
    if [ "$2" = "$3" ]; then echo "PASS  $1"; PASS=$((PASS + 1))
    else echo "FAIL  $1  (got '$2', want '$3')"; FAIL=$((FAIL + 1)); fi
}
fact() { cg "$1" facts | "$PY" -c "import json,sys; v=json.load(sys.stdin)['$2']; print('null' if v is None else str(v).lower() if isinstance(v,bool) else v)"; }

echo "-- which session is current --"
g checkout -q -b feature/A-1-a
session "$REPO" 20261001-100000-a feature/A-1-a IMPLEMENTING
session "$REPO" 20261001-090000-b feature/B-2-b PR_CREATED
is "the session of the checked-out branch"           "$(cg "$REPO" current)" 20261001-100000-a
g checkout -q -b feature/B-2-b main
g commit -q --allow-empty -m "b work"
is "switching branch switches the task"              "$(cg "$REPO" current)" 20261001-090000-b
g checkout -q -b feature/C-3-c main
is "a branch without a session has none"             "$(cg "$REPO" current)" ""
mkdir -p "$REPO/.ai/sessions/20260901-100000-old"
echo "[t] Branch feature/C-3-c from main" > "$REPO/.ai/sessions/20260901-100000-old/audit.log"
is "an older session names its branch in the audit"  "$(cg "$REPO" current)" 20260901-100000-old
rm -rf "$REPO/.ai/sessions/20260901-100000-old"
mkdir -p "$REPO/.ai/sessions/legacy"
echo legacy > "$REPO/.ai/current-session"
is "a session naming no branch: the old pointer"     "$(cg "$REPO" current)" legacy
echo 20261001-100000-a > "$REPO/.ai/current-session"
is "the pointer never overrides another branch's task" "$(cg "$REPO" current)" ""
rm -rf "$REPO/.ai/sessions/legacy" "$REPO/.ai/current-session"
session "$REPO" 20261002-100000-c2 feature/C-3-c IDLE
mkdir -p "$REPO/.ai/sessions/20261001-100000-c1"; echo feature/C-3-c > "$REPO/.ai/sessions/20261001-100000-c1/branch"
is "two sessions on one branch: the latest"          "$(cg "$REPO" current)" 20261002-100000-c2

echo ""
echo "-- the shared copy outlives a worktree --"
g checkout -q main
cg "$REPO" sync
WT="$ROOT/wt"
g worktree add -q "$WT" feature/A-1-a
install_into "$WT"
is "a new worktree finds its branch's session"       "$(cg "$WT" current)" 20261001-100000-a
is "and restores the files from the shared copy"     "$(cg "$WT" dir >/dev/null; cat "$WT/.ai/sessions/20261001-100000-a/state")" IMPLEMENTING
sleep 1
echo QUALITY_REVIEWED > "$WT/.ai/sessions/20261001-100000-a/state"
cg "$WT" sync
g worktree remove --force "$WT"
WT2="$ROOT/wt2"
g worktree add -q "$WT2" feature/A-1-a
install_into "$WT2"
is "work done in a removed worktree survives"        "$(cg "$WT2" dir >/dev/null; cat "$WT2/.ai/sessions/20261001-100000-a/state")" QUALITY_REVIEWED
is "a stale local copy does not win over a newer one" "$(cg "$REPO" list | grep 20261001-100000-a | awk '{print $3}')" QUALITY_REVIEWED
g worktree remove --force "$WT2"

echo ""
echo "-- activity is read from the audit log, not from file dates --"
# A checkout of tracked session files writes old content with today's date.
OLD="$REPO/.ai/sessions/20260101-100000-old"
mkdir -p "$OLD"
echo feature/O-9-o > "$OLD/branch"
echo IMPLEMENTING > "$OLD/state"
printf '[2026-01-01T09:00:00] Session started\n[2026-01-01T10:00:00] commit: abc\n' > "$OLD/audit.log"
seen() { cg "$REPO" list --json | "$PY" -c "import json,sys; print([r['last_activity'] for r in json.load(sys.stdin) if r['id']=='$1'][0])"; }
is "a freshly written old session: its last entry"   "$(seen 20260101-100000-old)" "2026-01-01 10:00"
cg "$REPO" sync
STORE="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/codegate/sessions/20260101-100000-old"
sleep 1
echo PR_CREATED > "$STORE/state"
echo "[2026-01-02T10:00:00] PR created" >> "$STORE/audit.log"
sleep 1
echo IMPLEMENTING > "$OLD/state"
printf '[2026-01-01T09:00:00] Session started\n[2026-01-01T10:00:00] commit: abc\n' > "$OLD/audit.log"
is "an older copy with fresh dates is not read"      "$(cg "$REPO" list --json | "$PY" -c "import json,sys; print([r['state'] for r in json.load(sys.stdin) if r['id']=='20260101-100000-old'][0])")" PR_CREATED
cg "$REPO" sync
is "nor does sync write it over the newer one"       "$(cat "$STORE/state")" PR_CREATED
rm -rf "$OLD" "$STORE"

echo ""
echo "-- facts about the checkout --"
is "on the base branch"                              "$(fact "$REPO" status)" base
g checkout -q feature/B-2-b
is "an open MR"                                      "$(fact "$REPO" status)" review-open
g checkout -q feature/C-3-c
echo x > "$REPO/tracked.txt" && g add tracked.txt && g commit -q -m "wip"
echo y >> "$REPO/tracked.txt"
is "uncommitted changes: in progress"                "$(fact "$REPO" status)" in-progress
is "and the new task goes to a new worktree"         "$(fact "$REPO" folder)" new-worktree
g checkout -q -- tracked.txt
is "committed, unmerged, recent: paused"             "$(fact "$REPO" status)" paused
echo "[t] commit: $(g rev-parse --short HEAD) — feat: x" >> "$REPO/.ai/sessions/20261002-100000-c2/audit.log"
g checkout -q main && g merge -q --ff-only feature/C-3-c && g checkout -q feature/C-3-c
is "its commits are in the target: merged"           "$(fact "$REPO" status)" merged
g checkout -q -b feature/D-4-d main
is "no session on the branch"                        "$(fact "$REPO" status)" no-session
sleep 1
echo new > "$REPO/NewService.kt"
is "a new uncommitted file is work in progress"      "$(fact "$REPO" status)" in-progress
rm "$REPO/NewService.kt"
g checkout -q main
echo z > "$REPO/tracked.txt"
is "uncommitted edits on the base branch are not 'base'" "$(fact "$REPO" status)" in-progress
g checkout -q -- tracked.txt
g checkout -q --detach feature/A-1-a
mkdir -p "$REPO/.git/rebase-merge" && echo refs/heads/feature/A-1-a > "$REPO/.git/rebase-merge/head-name"
is "mid-rebase (detached) the rebased branch's task" "$(cg "$REPO" current)" 20261001-100000-a
rm -rf "$REPO/.git/rebase-merge"
g checkout -q feature/D-4-d

echo ""
echo "-- who works in this folder --"
is "first chat: nobody else"                         "$(cg "$REPO" claim --chat one)" "{}"
is "the same chat again: nobody else"                "$(cg "$REPO" claim --chat one)" "{}"
case "$(cg "$REPO" claim --chat two)" in *'"other_chat": "one"'*) is "a second chat sees the first" yes yes ;; *) is "a second chat sees the first" no yes ;; esac

echo ""
echo "-- task-context.sh: the line on every message --"
hook() { ( cd "$REPO" && printf '{"session_id":"%s","cwd":"%s"}' "$2" "$REPO" | bash ".claude/hooks/$1" 2>&1 ); }
g checkout -q feature/A-1-a
OUT=$(hook task-context.sh two)
case "$OUT" in *"task "*"feature/A-1-a"*"QUALITY_REVIEWED"*) is "names the task and its state" yes yes ;; *) is "names the task and its state ($OUT)" no yes ;; esac
g checkout -q feature/B-2-b
OUT=$(hook task-context.sh two)
case "$OUT" in *"MR open"*cg-rework*) is "an open MR points at rework" yes yes ;; *) is "an open MR points at rework ($OUT)" no yes ;; esac
g checkout -q feature/D-4-d
OUT=$(hook task-context.sh two)
case "$OUT" in *"no task on 'feature/D-4-d'"*) is "no task on the branch is said" yes yes ;; *) is "no task on the branch is said ($OUT)" no yes ;; esac
OUT=$(hook task-context.sh three)
case "$OUT" in *"Another chat worked in this folder"*) is "another live chat in the folder is flagged" yes yes ;; *) is "another live chat in the folder is flagged ($OUT)" no yes ;; esac

echo ""
echo "-- pre-agent.sh: elicitation and planning need a task --"
agent() {
    local json
    json=$("$PY" -c "import json,sys; print(json.dumps({'tool_input': {'prompt': sys.argv[1]}}))" "$1")
    ( cd "$REPO" && printf '%s' "$json" | bash .claude/hooks/pre-agent.sh >/dev/null 2>&1 ); echo $?
}
is "elicitation without a task is blocked"     "$(agent 'Use .claude/agents/elicitation/prompt.md for X')" 2
is "any other sub-agent is not this hook's business" "$(agent 'Explore the auth code')" 0
g checkout -q feature/A-1-a
echo IDLE > "$REPO/.ai/sessions/20261001-100000-a/state"
is "elicitation inside a task passes"          "$(agent 'Use .claude/agents/elicitation/prompt.md')" 0
g checkout -q feature/B-2-b
is "planning for a task past its MR is blocked" "$(agent 'Run .claude/agents/planning/prompt.md')" 2
echo REWORK > "$REPO/.ai/sessions/20261001-090000-b/state"
is "but a scoped rework may elicit"            "$(agent 'Use .claude/agents/elicitation/prompt.md')" 0

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
