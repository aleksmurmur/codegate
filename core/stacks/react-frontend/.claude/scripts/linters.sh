#!/usr/bin/env bash
# The linters this project has configured, as `name<TAB>command` lines, check mode only.
# Read by gate-checks.sh; run from the project root.

has() { for f in "$@"; do [ -e "$f" ] && return 0; done; return 1; }

if has eslint.config.js eslint.config.mjs eslint.config.cjs eslint.config.ts .eslintrc .eslintrc.js .eslintrc.cjs .eslintrc.json .eslintrc.yml .eslintrc.yaml \
   || grep -qs '"eslintConfig"' package.json; then
  printf 'eslint\tnpx eslint . --max-warnings=0\n'
fi
if [ -f tsconfig.json ]; then
  printf 'tsc\tnpx tsc --noEmit\n'
fi
if has .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml .prettierrc.js .prettierrc.cjs .prettierrc.mjs prettier.config.js prettier.config.cjs prettier.config.mjs \
   || grep -qs '"prettier"[[:space:]]*:[[:space:]]*{' package.json; then
  printf 'prettier\tnpx prettier --check .\n'
fi
exit 0
