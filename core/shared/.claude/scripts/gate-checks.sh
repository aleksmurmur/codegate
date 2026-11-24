#!/usr/bin/env bash
# Run the quality gate's checks that need no judgement: the stack's linters (check mode only,
# never a formatter's write mode) and the project's own commands from the option `gate_checks`.
#
# Usage: gate-checks.sh --output <report.md>
# The stack's `linters.sh`, next to this script, prints `name<TAB>command` for every linter the
# project has configured. `gate_checks` holds commands separated by ` ;; `.
# Each command runs from the current directory; its full output goes to <report>-<n>.log.
# Exit 0 when every check passed (or there were none), 1 when any failed, 2 on a usage error.
set -u

usage() { echo "usage: gate-checks.sh --output <report.md>" >&2; exit 2; }
OUTPUT=
while [ $# -gt 0 ]; do
  case "$1" in
    --output) [ $# -ge 2 ] || usage; OUTPUT="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$OUTPUT" ] || usage

HERE="$(cd "$(dirname "$0")" && pwd)"
CHECKS=$(mktemp)
DETAILS=$(mktemp)
trap 'rm -f "$CHECKS" "$DETAILS"' EXIT

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
  printf 'project check %s\t%s\n' "$n" "$cmd" >> "$CHECKS"
done

{
  echo "# Checks"
  echo
  if [ -s "$CHECKS" ]; then
    echo "| Check | Command | Result | Log |"
    echo "|---|---|---|---|"
  else
    echo "No linter configured and no project checks (option \`gate_checks\`)."
  fi
} > "$OUTPUT"

BASE="${OUTPUT%.md}"
FAILED=0
i=0
while IFS=$'\t' read -r name cmd; do
  [ -n "$cmd" ] || continue
  i=$((i + 1))
  log="$BASE-$i.log"
  bash -c "$cmd" > "$log" 2>&1 < /dev/null
  code=$?
  if [ "$code" -eq 0 ]; then
    result="pass"
  else
    result="fail (exit $code)"
    FAILED=1
    { echo; echo "## $name — fail (exit $code)"; echo; echo '```'; tail -n 40 "$log"; echo '```'; } >> "$DETAILS"
  fi
  echo "| $name | \`$cmd\` | $result | \`$log\` |" >> "$OUTPUT"
done < "$CHECKS"
cat "$DETAILS" >> "$OUTPUT"

echo "Checks: $i run, $([ "$FAILED" = 1 ] && echo FAIL || echo CLEAN)"
exit "$FAILED"
