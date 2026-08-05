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

# check <name> <fixture> <want_exit> <want_verdict> [report_substring]
# The optional 5th argument must appear in integrity-report.md — used for
# non-blocking warnings, which the verdict alone cannot distinguish.
check() {
    local name="$1"
    local fixture="$2"
    local want_exit="$3"
    local want_verdict="$4"
    local want_report="${5:-}"

    local tmpdir
    tmpdir=$(mktemp -d)
    cp "$fixture" "$tmpdir/PLAN.md"

    python3 "$SCRIPT" "$tmpdir/PLAN.md" >/dev/null 2>&1
    local got_exit=$?
    local got_verdict
    got_verdict=$(grep -m1 '^\*\*Status\*\*' "$tmpdir/integrity-report.md" 2>/dev/null \
                  | sed 's/.*: //')

    local report_ok="yes"
    if [ -n "$want_report" ]; then
        grep -qF -- "$want_report" "$tmpdir/integrity-report.md" 2>/dev/null || report_ok="no"
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
check "create-collision"     "$FIXTURES_DIR/create-collision.md"     0 "CLEAN" "already exists"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
