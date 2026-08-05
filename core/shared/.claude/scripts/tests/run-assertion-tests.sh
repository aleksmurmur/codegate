#!/bin/bash
# Fixture tests for test-assertions.py.
#
# Builds a throwaway git repo so the script has a real `base..HEAD` to diff:
# `base/` becomes the first commit, `work/` the second. Files present only in
# `work/` are new; files in both exercise the "only functions touched by this
# diff are examined" rule.
#
#   .claude/scripts/tests/run-assertion-tests.sh
#
# Exits 0 if all assertions hold, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$SCRIPT_DIR/assertion-fixtures"
SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/test-assertions.py"
PASS=0
FAIL=0

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

cd "$WORKDIR" || exit 2
git init -q .
git config user.email codegate@test
git config user.name codegate
mkdir -p src/test

cp "$FIXTURES"/base/* src/test/ 2>/dev/null
git add -A >/dev/null && git commit -qm base
BASE=$(git rev-parse HEAD)

cp "$FIXTURES"/work/* src/test/
git add -A >/dev/null && git commit -qm work

python3 "$SCRIPT" --base "$BASE" --output report.md >/dev/null 2>&1
EXIT=$?
REPORT=$(cat report.md 2>/dev/null)

expect_exit() {
    if [ "$EXIT" = "$1" ]; then
        echo "PASS  exit code is $1"; PASS=$((PASS + 1))
    else
        echo "FAIL  exit code: want $1, got $EXIT"; FAIL=$((FAIL + 1))
    fi
}

# $1 = human name, $2 = grep pattern, $3 = "yes" if it must appear
expect_line() {
    local name="$1" pattern="$2" want="$3" got="no"
    echo "$REPORT" | grep -qF -- "$pattern" && got="yes"
    if [ "$got" = "$want" ]; then
        echo "PASS  $name"; PASS=$((PASS + 1))
    else
        echo "FAIL  $name  (want present=$want, got present=$got)"; FAIL=$((FAIL + 1))
    fi
}

expect_exit 1

# Blocking tier — asserts nothing at all, or only that nothing threw.
expect_line "kotlin: no-throw only is blocking"      "no throw only" yes
expect_line "kotlin: empty assertion is blocking"    "asserts nothing" yes
expect_line "ts: .not.toThrow() is blocking"         "does not throw" yes
expect_line "python: no assert is blocking"          "test_no_assert" yes
expect_line "go: no assert is blocking"              "TestNothing" yes

# Advisory tier — existence-only.
expect_line "kotlin: assertNotNull is advisory"      "existence only" yes
expect_line "ts: toBeInTheDocument is advisory"      "renders the title" yes
expect_line "python: is not None is advisory"        "test_existence" yes

# Clean — a real assertion, in each language's own idiom.
expect_line "kotlin: assertEquals is clean"          "real assertion" no
expect_line "ts: toEqual is clean"                   "computes" no
expect_line "python: bare assert is clean"           "test_bare_assert" no
expect_line "go: t.Errorf is clean"                  "TestErrorf" no

# Fixture helpers are not tests — an unannotated `fun` must not be reported.
expect_line "kotlin: private fixture helper ignored" "makeThing" no

# Lexer — braces inside strings and comments must not truncate the body.
expect_line "kotlin: braces in literals are ignored" "braces in strings" no

# Scope — a weak test the diff never touched is not this task's problem.
expect_line "untouched weak test is not reported"    "untouched by the diff" no
expect_line "touched weak test is reported"          "touched by the diff" yes

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
