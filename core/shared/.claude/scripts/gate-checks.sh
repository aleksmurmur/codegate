#!/usr/bin/env bash
# Run the quality gate's checks that need no judgement: the stack's linters (check mode only,
# never a formatter's write mode) and the project's own commands from the option `gate_checks`.
#
# Usage: gate-checks.sh [--base <commit>] --output <report.md>
# Every check, and the stack's `linters.sh` (next to this script), gets CG_BASE (the task's
# base commit) and CG_CHANGED_FILES (the files `<base>..HEAD` adds or changes, one per line).
# `linters.sh` prints `name<TAB>scope<TAB>command` per configured linter; scope is
# `changed files` or `whole project`. `gate_checks` holds commands separated by ` ;; `.
# Each check runs from the current directory to its end, with no time limit: a check cut
# short is a check skipped. Its output goes to <report>-<n>.log. The report is written when
# the run ends, so a run cut off leaves no report, never a partial one.
# Exit 0 when every check passed (or there were none), 1 when any failed, 2 on a usage error.
set -u

usage() { echo "usage: gate-checks.sh [--base <commit>] --output <report.md>" >&2; exit 2; }
OUTPUT=
CG_BASE=
while [ $# -gt 0 ]; do
  case "$1" in
    --output) [ $# -ge 2 ] || usage; OUTPUT="$2"; shift 2 ;;
    --base) [ $# -ge 2 ] || usage; CG_BASE="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$OUTPUT" ] || usage

HERE="$(cd "$(dirname "$0")" && pwd)"
LOG_PREFIX="${OUTPUT%.md}"
rm -f "$OUTPUT" "$LOG_PREFIX"-[0-9]*.log
CHECKS=$(mktemp)
DETAILS=$(mktemp)
ROWS=$(mktemp)
trap 'rm -f "$CHECKS" "$DETAILS" "$ROWS" "$OUTPUT.tmp"' EXIT

CG_CHANGED_FILES=
if [ -n "$CG_BASE" ]; then
  CG_CHANGED_FILES=$(git diff --name-only --diff-filter=d "$CG_BASE..HEAD" 2>/dev/null) \
    || { echo "gate-checks: cannot diff $CG_BASE..HEAD" >&2; exit 2; }
fi
export CG_BASE CG_CHANGED_FILES

[ -f "$HERE/linters.sh" ] && bash "$HERE/linters.sh" >> "$CHECKS"

rest=$(bash "$HERE/cg-option.sh" gate_checks 2>/dev/null || true)
n=0
while [ -n "$rest" ]; do
  case "$rest" in
    *" ;; "*) cmd="${rest%% ;; *}"; rest="${rest#* ;; }" ;;
    *) cmd="$rest"; rest= ;;
  esac
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}"
  [ -n "$cmd" ] || continue
  n=$((n + 1))
  printf 'project check %s\tproject\t%s\n' "$n" "$cmd" >> "$CHECKS"
done

# A Markdown table cell: `|` and backticks would end the cell or open a code span.
cell() { local s="$1"; s="${s//\\/\\\\}"; s="${s//|/\\|}"; s="${s//\`/\\\`}"; printf '%s' "$s"; }

FAILED=0
i=0
while IFS=$'\t' read -r name scope cmd; do
  [ -n "$cmd" ] || continue
  i=$((i + 1))
  log="$LOG_PREFIX-$i.log"
  bash -c "$cmd" > "$log" 2>&1 < /dev/null
  code=$?
  if [ "$code" -eq 0 ]; then
    result="pass"
  else
    result="fail (exit $code)"
    FAILED=1
    { echo; echo "## $name — fail (exit $code)"; echo; echo '```'; tail -n 40 "$log"; echo '```'; } >> "$DETAILS"
  fi
  echo "| $(cell "$name") | $scope | $(cell "$cmd") | $result | $(cell "$log") |" >> "$ROWS"
done < "$CHECKS"

if [ "$FAILED" = 1 ]; then VERDICT=FAIL; else VERDICT=CLEAN; fi

{
  echo "# Checks"
  echo
  if [ "$i" -gt 0 ]; then
    echo "Base: ${CG_BASE:-none given — every check saw the whole project}"
    echo
    echo "| Check | Scope | Command | Result | Log |"
    echo "|---|---|---|---|---|"
    cat "$ROWS"
  else
    echo "No linter configured and no project checks (option \`gate_checks\`)."
  fi
  cat "$DETAILS"
  echo
  echo "Checks: $i run, $VERDICT"
} > "$OUTPUT.tmp"
mv "$OUTPUT.tmp" "$OUTPUT"

echo "Checks: $i run, $VERDICT"
[ "$FAILED" = 1 ] && exit 1
exit 0
