#!/bin/bash
# Fixture tests for plan-integrity.py.
# Must be run from the repo root so `git ls-files` and file-existence checks
# resolve against the codegate repo that the fixtures reference.
#
#   .claude/scripts/tests/run-tests.sh
#
# Exits 0 if all assertions hold, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/plan-integrity.py"
PASS=0
FAIL=0

check() {
    local name="$1"
    local fixture="$2"
    local want_exit="$3"
    local want_verdict="$4"

    local tmpdir
    tmpdir=$(mktemp -d)
    cp "$fixture" "$tmpdir/PLAN.md"

    python3 "$SCRIPT" "$tmpdir/PLAN.md" >/dev/null 2>&1
    local got_exit=$?
    local got_verdict
    got_verdict=$(grep -m1 '^\*\*Status\*\*' "$tmpdir/integrity-report.md" 2>/dev/null \
                  | sed 's/.*: //')

    if [ "$got_exit" = "$want_exit" ] && [ "$got_verdict" = "$want_verdict" ]; then
        echo "PASS  $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $name  (want exit=$want_exit verdict=$want_verdict;" \
             "got exit=$got_exit verdict=$got_verdict)"
        FAIL=$((FAIL + 1))
    fi
    rm -rf "$tmpdir"
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
