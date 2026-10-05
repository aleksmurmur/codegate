#!/bin/bash
# Tests for cg-option.sh — how workflow steps read the options /cg-start recorded.
#
# The options block sits between the manifest header and the `files:` list, whose
# entries are also indented `key: value` lines. These cases pin that a lookup never
# leaks into `files:`, survives CRLF, and falls back to the caller's default.
#
#   core/tests/run-option-tests.sh          (from the cg-core checkout)
#
# Exits 0 if all assertions hold, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$(cd "$SCRIPT_DIR/../shared/.claude/scripts" && pwd)/cg-option.sh"
PASS=0
FAIL=0

[ -f "$SCRIPT" ] || { echo "ERROR: cg-option.sh not found at $SCRIPT"; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/manifest.yml" <<'EOF'
codegate_version: abc
stack: kotlin-backend
ref: main
options:
  base_branch: develop
  tracker: adapter
files:
  - path: CLAUDE.md
    source: shared/CLAUDE.md
    sha256: 123
EOF
sed 's/$/\r/' "$WORK/manifest.yml" > "$WORK/manifest-crlf.yml"
grep -v '^options:\|^  base_branch\|^  tracker' "$WORK/manifest.yml" > "$WORK/manifest-no-options.yml"

# check <name> <manifest> <want_stdout> <want_exit> <args...>
check() {
    local name="$1" manifest="$2" want_out="$3" want_exit="$4"; shift 4
    local got_out got_exit
    got_out=$(CG_MANIFEST="$manifest" bash "$SCRIPT" "$@" 2>/dev/null)
    got_exit=$?
    if [ "$got_out" = "$want_out" ] && [ "$got_exit" = "$want_exit" ]; then
        echo "PASS  $name"; PASS=$((PASS + 1))
    else
        echo "FAIL  $name  (want '$want_out'/$want_exit, got '$got_out'/$got_exit)"; FAIL=$((FAIL + 1))
    fi
}

check "reads a recorded option"            "$WORK/manifest.yml"            "develop" 0 base_branch
check "reads the second option"            "$WORK/manifest.yml"            "adapter" 0 tracker
check "recorded value beats the default"   "$WORK/manifest.yml"            "develop" 0 base_branch main
check "absent key falls back to default"   "$WORK/manifest.yml"            "none"    0 missing none
check "absent key without default fails"   "$WORK/manifest.yml"            ""        1 missing
check "never reads keys from files:"       "$WORK/manifest.yml"            ""        1 source
check "CRLF manifest yields a clean value" "$WORK/manifest-crlf.yml"       "develop" 0 base_branch
check "manifest without options: default"  "$WORK/manifest-no-options.yml" "main"    0 base_branch main
check "missing manifest uses the default"  "$WORK/nope.yml"                "main"    0 base_branch main
check "missing manifest, no default"       "$WORK/nope.yml"                ""        2 base_branch

echo ""
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
