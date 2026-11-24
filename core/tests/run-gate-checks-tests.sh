#!/bin/bash
# Tests for gate-checks.sh and the stacks' linters.sh — the gate's checks that are commands.
#
# Each case builds a throwaway project with the scripts installed where the workflow puts
# them (`.claude/scripts/`), so gate-checks.sh finds its linters.sh and cg-option.sh beside it.
#
#   core/tests/run-gate-checks-tests.sh          (from the cg-core checkout)
#
# Exits 0 if all assertions hold, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORE="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ok()  { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $1  ($2)"; FAIL=$((FAIL + 1)); }

# project <name> [stack] — a fresh project dir with the scripts installed
project() {
    local dir="$WORK/$1"
    mkdir -p "$dir/.claude/scripts"
    cp "$CORE/shared/.claude/scripts/gate-checks.sh" "$CORE/shared/.claude/scripts/cg-option.sh" "$dir/.claude/scripts/"
    [ -n "${2-}" ] && cp "$CORE/stacks/$2/.claude/scripts/linters.sh" "$dir/.claude/scripts/"
    echo "$dir"
}

# manifest <dir> <gate_checks value>
manifest() {
    printf 'codegate_version: abc\noptions:\n  gate_checks: %s\nfiles:\n  - path: CLAUDE.md\n' "$2" \
        > "$1/.claude/codegate-installed.yml"
}

# run <dir> — runs gate-checks from the project root; sets OUT and CODE
run() {
    OUT=$(cd "$1" && bash .claude/scripts/gate-checks.sh --output report.md 2>&1)
    CODE=$?
}

# --- no linters, no option -----------------------------------------------------
P=$(project empty)
run "$P"
[ "$CODE" = 0 ] && grep -q "No linter configured" "$P/report.md" \
    && ok "nothing to run passes and says so" || bad "nothing to run passes and says so" "exit $CODE"

# --- project checks from the option ----------------------------------------------
P=$(project option)
manifest "$P" "true ;; echo boom >&2; exit 3 ;; test -d .claude"
run "$P"
[ "$CODE" = 1 ] && ok "a failing project check fails the run" || bad "a failing project check fails the run" "exit $CODE"
[ "$(grep -c '^| project check' "$P/report.md")" = 3 ] \
    && ok "commands split on ' ;; ', one row each" || bad "commands split on ' ;; ', one row each" "$(cat "$P/report.md")"
grep -q '^| project check 2 | .* | fail (exit 3) |' "$P/report.md" \
    && ok "the failing check's exit code is recorded" || bad "the failing check's exit code is recorded" "$(cat "$P/report.md")"
grep -q '^boom$' "$P/report.md" && [ -f "$P/report-2.log" ] \
    && ok "a failure's output is in the report and its log" || bad "a failure's output is in the report and its log" "$(ls "$P")"
grep -q '^| project check 3 | .* | pass |' "$P/report.md" \
    && ok "a check runs from the project root" || bad "a check runs from the project root" "$(cat "$P/report.md")"

P=$(project passing)
manifest "$P" "true"
run "$P"
[ "$CODE" = 0 ] && ok "all checks passing exits 0" || bad "all checks passing exits 0" "exit $CODE"

# --- usage ---------------------------------------------------------------------
P=$(project usage)
OUT=$(cd "$P" && bash .claude/scripts/gate-checks.sh 2>&1); CODE=$?
[ "$CODE" = 2 ] && ok "no --output is a usage error" || bad "no --output is a usage error" "exit $CODE"

# --- the stacks' linter detection ----------------------------------------------
P=$(project kotlin kotlin-backend)
printf 'plugins { id("org.jlleitschuh.gradle.ktlint") ; id("io.gitlab.arturbosch.detekt") }\n' > "$P/build.gradle.kts"
L=$(cd "$P" && bash .claude/scripts/linters.sh)
printf '%s\n' "$L" | grep -q $'^ktlint\tgradle ktlintCheck$' && printf '%s\n' "$L" | grep -q $'^detekt\t' \
    && ok "kotlin: ktlint and detekt found in the build file" || bad "kotlin: ktlint and detekt found in the build file" "$L"
printf '%s\n' "$L" | grep -q checkstyle \
    && bad "kotlin: no checkstyle without its config" "$L" || ok "kotlin: no checkstyle without its config"

P=$(project react react-frontend)
printf '{}\n' > "$P/tsconfig.json"
printf '{ "devDependencies": { "prettier": "^3.0.0" } }\n' > "$P/package.json"
L=$(cd "$P" && bash .claude/scripts/linters.sh)
[ "$L" = $'tsc\tnpx tsc --noEmit' ] \
    && ok "react: tsc found; prettier as a dependency is not a config" || bad "react: tsc found; prettier as a dependency is not a config" "$L"
printf '{}\n' > "$P/.prettierrc"
L=$(cd "$P" && bash .claude/scripts/linters.sh)
printf '%s\n' "$L" | grep -q $'^prettier\tnpx prettier --check .$' \
    && ok "react: prettier runs in check mode" || bad "react: prettier runs in check mode" "$L"

# the stack's linters reach the report
P=$(project react-run react-frontend)
printf 'printf "fake\\ttrue\\n"\n' > "$P/.claude/scripts/linters.sh"
run "$P"
[ "$CODE" = 0 ] && grep -q '^| fake | `true` | pass |' "$P/report.md" \
    && ok "linters from linters.sh run and are reported" || bad "linters from linters.sh run and are reported" "$(cat "$P/report.md")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
