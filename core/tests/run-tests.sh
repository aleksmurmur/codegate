#!/bin/bash
# Fixture tests for plan-integrity.py.
#
# The script under test verifies that paths cited by a plan exist, checking
# against the current repo. That made the fixtures depend on wherever they
# happened to run: aimed at cg-core they broke in every installed project, and
# aimed at a project they broke in cg-core — both happened, on the same day.
# So the harness builds its own throwaway repo containing exactly the paths the
# fixtures cite, and runs there. The fixtures are now host-independent.
#
#   core/tests/run-tests.sh          (from the cg-core checkout)
#
# Exits 0 if all assertions hold, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
SCRIPT="$(cd "$SCRIPT_DIR/../shared/.claude/scripts" && pwd)/plan-integrity.py"
PASS=0
FAIL=0

[ -f "$SCRIPT" ] || { echo "ERROR: plan-integrity.py not found at $SCRIPT"; exit 2; }

# --- a repo shaped like a codegate-installed project --------------------------
REPO=$(mktemp -d)
trap 'rm -rf "$REPO"' EXIT

mkdir -p "$REPO/.claude/scripts/tests" "$REPO/src"
# CLAUDE.md carries the word `Checklist`, which the create-collision fixture
# expects `git grep -w` to find.
printf '# Project\n\n## Checklist\n\nPlans list their files here.\n' > "$REPO/CLAUDE.md"
printf '# Readme\n' > "$REPO/README.md"
printf '{}\n' > "$REPO/.claude/settings.json"
printf '# placeholder\n' > "$REPO/.claude/scripts/plan-integrity.py"
printf '# placeholder\n' > "$REPO/.claude/scripts/tests/run-tests.sh"

git -C "$REPO" init -q .
git -C "$REPO" config user.email codegate@test
git -C "$REPO" config user.name codegate
git -C "$REPO" add -A >/dev/null
git -C "$REPO" commit -qm "installed project"

# check <name> <fixture> <want_exit> <want_verdict> [report_substring]
# The optional 5th argument must appear in integrity-report.md — used for
# non-blocking warnings, which the verdict alone cannot distinguish.
check() {
    local name="$1"
    local fixture="$2"
    local want_exit="$3"
    local want_verdict="$4"
    local want_report="${5:-}"

    cp "$fixture" "$REPO/PLAN.md"

    ( cd "$REPO" && python3 "$SCRIPT" "$REPO/PLAN.md" ) >/dev/null 2>&1
    local got_exit=$?
    local got_verdict
    got_verdict=$(grep -m1 '^\*\*Status\*\*' "$REPO/integrity-report.md" 2>/dev/null \
                  | sed 's/.*: //')

    local report_ok="yes"
    if [ -n "$want_report" ]; then
        grep -qF -- "$want_report" "$REPO/integrity-report.md" 2>/dev/null || report_ok="no"
    fi

    if [ "$got_exit" = "$want_exit" ] && [ "$got_verdict" = "$want_verdict" ] \
       && [ "$report_ok" = "yes" ]; then
        echo "PASS  $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $name  (want exit=$want_exit verdict=$want_verdict" \
             "report_match=yes; got exit=$got_exit verdict=$got_verdict" \
             "report_match=$report_ok)"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$REPO/PLAN.md" "$REPO/integrity-report.md"
}

check "clean"                "$FIXTURES_DIR/clean.md"                0 "CLEAN"
check "mirage"               "$FIXTURES_DIR/mirage.md"               1 "MIRAGES_FOUND"
check "bullets"              "$FIXTURES_DIR/bullets.md"              0 "CLEAN"
check "malformed"            "$FIXTURES_DIR/malformed.md"            1 "PARSE_FAILED"
check "no-checklist"         "$FIXTURES_DIR/no-checklist.md"         1 "PARSE_FAILED"
check "missing-ac"           "$FIXTURES_DIR/missing-ac.md"           1 "MIRAGES_FOUND"
check "missing-commit-plan"  "$FIXTURES_DIR/missing-commit-plan.md"  1 "MIRAGES_FOUND"
check "ac-too-few"           "$FIXTURES_DIR/ac-too-few.md"           1 "MIRAGES_FOUND"
check "commit-plan-coverage" "$FIXTURES_DIR/commit-plan-coverage.md" 1 "MIRAGES_FOUND"
check "create-collision"     "$FIXTURES_DIR/create-collision.md"     0 "CLEAN" "already exists"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
