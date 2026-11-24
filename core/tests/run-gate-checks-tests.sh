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

# manifest <dir> <gate_checks value> [more option lines]
manifest() {
    local dir="$1" checks="$2"; shift 2
    {
        printf 'codegate_version: abc\noptions:\n  gate_checks: %s\n' "$checks"
        for line in "$@"; do printf '  %s\n' "$line"; done
        printf 'files:\n  - path: CLAUDE.md\n'
    } > "$dir/.claude/codegate-installed.yml"
}

# run <dir> [args] — runs gate-checks from the project root; sets OUT and CODE
run() {
    local dir="$1"; shift
    OUT=$(cd "$dir" && bash .claude/scripts/gate-checks.sh "$@" --output report.md 2>&1)
    CODE=$?
}

# git_project <dir> — a repo with one base commit (BASE_SHA) and one commit changing two files
git_project() {
    local g="git -C $1 -c user.email=t@t -c user.name=t -c core.autocrlf=false"
    $g init -q .
    $g commit -q --allow-empty -m base
    BASE_SHA=$($g rev-parse HEAD)
    mkdir -p "$1/src"
    echo x > "$1/src/a.ts"; echo y > "$1/notes.md"
    $g add src/a.ts notes.md
    $g commit -q -m change
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
tail -n 1 "$P/report.md" | grep -q '^Checks: 3 run, FAIL$' \
    && ok "the report ends with its verdict line" || bad "the report ends with its verdict line" "$(tail -n 2 "$P/report.md")"

P=$(project passing)
manifest "$P" "true"
run "$P"
[ "$CODE" = 0 ] && ok "all checks passing exits 0" || bad "all checks passing exits 0" "exit $CODE"

# --- a command with | and backticks keeps the table's columns --------------------
P=$(project escaping)
manifest "$P" 'echo a | grep a ;; echo `echo x`'
run "$P"
ROW=$(grep '^| project check 1 |' "$P/report.md")
CELLS=$(printf '%s' "$ROW" | sed 's/\\|//g' | tr -cd '|' | wc -c | tr -d ' ')
[ "$CELLS" = 6 ] && printf '%s' "$ROW" | grep -qF 'echo a \| grep a' \
    && ok "a | in a command is escaped in its row" || bad "a | in a command is escaped in its row" "$ROW"
grep '^| project check 2 |' "$P/report.md" | grep -qF 'echo \`echo x\`' \
    && ok "backticks in a command are escaped in its row" || bad "backticks in a command are escaped in its row" "$(cat "$P/report.md")"

# --- a slow check runs to its end; the report is never partial --------------------
P=$(project slow)
manifest "$P" "sleep 3 && true ;; true"
run "$P"
[ "$CODE" = 0 ] && grep -q '^| project check 1 | .* | pass |' "$P/report.md" \
    && ok "a slow check runs to its end, no time limit" || bad "a slow check runs to its end, no time limit" "exit $CODE: $(cat "$P/report.md")"

P=$(project cut-off)
manifest "$P" "sleep 4"
echo "stale" > "$P/report.md"; echo "stale" > "$P/report-7.log"
(cd "$P" && exec bash .claude/scripts/gate-checks.sh --output report.md >/dev/null 2>&1) &
RUNNER=$!
sleep 1
kill "$RUNNER" 2>/dev/null
wait "$RUNNER" 2>/dev/null
[ ! -f "$P/report.md" ] && ok "a run cut off leaves no report, not a stale or partial one" \
    || bad "a run cut off leaves no report, not a stale or partial one" "$(cat "$P/report.md")"
[ ! -f "$P/report-7.log" ] && ok "logs of an earlier run are cleared" || bad "logs of an earlier run are cleared" "$(ls "$P")"
sleep 4  # let the orphaned check end before the directory is removed

# --- the checks get the task's base and changed files ----------------------------
P=$(project scoped)
git_project "$P"
manifest "$P" 'test "$CG_BASE" = "$(git rev-parse HEAD~1)" && [ "$(printf "%s\n" "$CG_CHANGED_FILES" | sort | tr "\n" " ")" = "notes.md src/a.ts " ]'
run "$P" --base "$BASE_SHA"
[ "$CODE" = 0 ] && ok "a project check gets CG_BASE and CG_CHANGED_FILES" || bad "a project check gets CG_BASE and CG_CHANGED_FILES" "exit $CODE: $OUT"

# --- usage ---------------------------------------------------------------------
P=$(project usage)
OUT=$(cd "$P" && bash .claude/scripts/gate-checks.sh 2>&1); CODE=$?
[ "$CODE" = 2 ] && ok "no --output is a usage error" || bad "no --output is a usage error" "exit $CODE"

# --- the kotlin stack's linter detection ---------------------------------------
P=$(project kotlin kotlin-backend)
printf 'plugins { id("org.jlleitschuh.gradle.ktlint") ; id("io.gitlab.arturbosch.detekt") }\n' > "$P/build.gradle.kts"
L=$(cd "$P" && bash .claude/scripts/linters.sh)
printf '%s\n' "$L" | grep -q $'^ktlint\twhole project\tgradle ktlintCheck$' && printf '%s\n' "$L" | grep -q $'^detekt\t' \
    && ok "kotlin: ktlint and detekt found by their plugin ids" || bad "kotlin: ktlint and detekt found by their plugin ids" "$L"
printf '%s\n' "$L" | grep -q checkstyle \
    && bad "kotlin: no checkstyle without its plugin" "$L" || ok "kotlin: no checkstyle without its plugin"

P=$(project spotless kotlin-backend)
printf 'plugins { id("com.diffplug.spotless") }\n// ktlint rules below\nspotless { kotlin { ktlint() } }\n' > "$P/build.gradle.kts"
L=$(cd "$P" && bash .claude/scripts/linters.sh)
[ "$L" = $'spotless\twhole project\tgradle spotlessCheck' ] \
    && ok "kotlin: Spotless runs spotlessCheck; a mention of ktlint is not the ktlint plugin" || bad "kotlin: Spotless runs spotlessCheck; a mention of ktlint is not the ktlint plugin" "$L"

P=$(project convention kotlin-backend)
mkdir -p "$P/build-logic/src/main/kotlin" "$P/app"
printf 'plugins { id("my.conventions") }\n' > "$P/app/build.gradle.kts"
printf 'plugins { id("org.jmailen.kotlinter") }\n' > "$P/build-logic/src/main/kotlin/my.conventions.gradle.kts"
L=$(cd "$P" && bash .claude/scripts/linters.sh)
[ "$L" = $'kotlinter\twhole project\tgradle lintKotlin' ] \
    && ok "kotlin: a plugin applied in build-logic is found; kotlinter runs lintKotlin" || bad "kotlin: a plugin applied in build-logic is found; kotlinter runs lintKotlin" "$L"

P=$(project maven kotlin-backend)
printf '<project><build><plugins><plugin><artifactId>maven-checkstyle-plugin</artifactId></plugin></plugins></build></project>\n' > "$P/pom.xml"
L=$(cd "$P" && bash .claude/scripts/linters.sh)
[ "$L" = $'checkstyle\twhole project\tmvn -q checkstyle:check' ] \
    && ok "kotlin: a Maven project runs its plugin's check goal, no Gradle task" || bad "kotlin: a Maven project runs its plugin's check goal, no Gradle task" "$L"
printf '<project/>\n' > "$P/pom.xml"
L=$(cd "$P" && bash .claude/scripts/linters.sh)
[ -z "$L" ] && ok "kotlin: a Maven project without lint plugins runs nothing" || bad "kotlin: a Maven project without lint plugins runs nothing" "$L"

# --- the react stack's linter detection ----------------------------------------
P=$(project react react-frontend)
printf '{}\n' > "$P/tsconfig.json"
printf '{ "devDependencies": { "prettier": "^3.0.0" } }\n' > "$P/package.json"
L=$(cd "$P" && bash .claude/scripts/linters.sh)
[ "$L" = $'tsc\twhole project\tnpx tsc --noEmit' ] \
    && ok "react: tsc found; prettier as a dependency is not a config" || bad "react: tsc found; prettier as a dependency is not a config" "$L"
printf '{}\n' > "$P/.prettierrc"
L=$(cd "$P" && bash .claude/scripts/linters.sh)
printf '%s\n' "$L" | grep -q $'^prettier\twhole project\tnpx prettier --check .$' \
    && ok "react: prettier runs in check mode" || bad "react: prettier runs in check mode" "$L"

printf '{}\n' > "$P/.eslintrc.json"
L=$(cd "$P" && CG_BASE=abc CG_CHANGED_FILES=$'src/a b.tsx\nREADME.md' bash .claude/scripts/linters.sh)
printf '%s\n' "$L" | grep -qF $'eslint\tchanged files\tnpx eslint --max-warnings=0 src/a\\ b.tsx' \
    && ok "react: with a base, eslint sees only the changed script files" || bad "react: with a base, eslint sees only the changed script files" "$L"
printf '%s\n' "$L" | grep -qF $'prettier\tchanged files\tnpx prettier --check --ignore-unknown src/a\\ b.tsx README.md' \
    && ok "react: with a base, prettier sees the changed files" || bad "react: with a base, prettier sees the changed files" "$L"
L=$(cd "$P" && CG_BASE=abc CG_CHANGED_FILES=README.md bash .claude/scripts/linters.sh)
printf '%s\n' "$L" | grep -q '^eslint' \
    && bad "react: no changed script file, no eslint run" "$L" || ok "react: no changed script file, no eslint run"

# the stack's linters reach the report
P=$(project react-run react-frontend)
printf 'printf "fake\\twhole project\\ttrue\\n"\n' > "$P/.claude/scripts/linters.sh"
run "$P"
[ "$CODE" = 0 ] && grep -q '^| fake | whole project | true | pass |' "$P/report.md" \
    && ok "linters from linters.sh run and are reported" || bad "linters from linters.sh run and are reported" "$(cat "$P/report.md")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
