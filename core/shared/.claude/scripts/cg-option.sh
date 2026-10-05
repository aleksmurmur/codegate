#!/usr/bin/env bash
# Print a project option recorded by /cg-start in the manifest's `options:` block.
#
# Usage: cg-option.sh <key> [default]
# Prints the value, or the default when the key is absent. Exit 0 when a value
# (or default) was printed, 1 when neither exists, 2 when the manifest is missing.
set -euo pipefail

KEY="${1:?usage: cg-option.sh <key> [default]}"
DEFAULT="${2-}"
MANIFEST="${CG_MANIFEST:-.claude/codegate-installed.yml}"

[ -f "$MANIFEST" ] || { [ -n "$DEFAULT" ] && { echo "$DEFAULT"; exit 0; }; exit 2; }

VALUE=$(awk -v want="$KEY" '
  /^options:[[:space:]]*$/ { in_opts=1; next }
  in_opts && /^[^[:space:]]/ { in_opts=0 }
  in_opts && $1 == want":" { sub(/^[[:space:]]*[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }
' "$MANIFEST")

if [ -n "$VALUE" ]; then echo "$VALUE"; exit 0; fi
if [ -n "$DEFAULT" ]; then echo "$DEFAULT"; exit 0; fi
exit 1
