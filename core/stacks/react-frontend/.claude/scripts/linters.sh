#!/usr/bin/env bash
# The linters this project has configured, as `name<TAB>scope<TAB>command` lines, check mode
# only. Read by gate-checks.sh, which sets CG_BASE and CG_CHANGED_FILES; run from the project root.
# ESLint and Prettier take files, so with a base they see only the changed ones (and are left
# out when none of those is theirs); tsc checks the whole project.

has() { for f in "$@"; do [ -e "$f" ] && return 0; done; return 1; }

# changed <extended regex> — the changed files matching it, shell-quoted, space-separated.
changed() {
  printf '%s\n' "${CG_CHANGED_FILES-}" | grep -E "$1" | while IFS= read -r f; do printf ' %q' "$f"; done
}

# emit <name> <whole-project command> <files command prefix> <file regex>
emit() {
  if [ -z "${CG_BASE-}" ]; then
    printf '%s\twhole project\t%s\n' "$1" "$2"
  else
    local files
    files=$(changed "$4")
    [ -n "$files" ] && printf '%s\tchanged files\t%s%s\n' "$1" "$3" "$files"
  fi
  return 0
}

if has eslint.config.js eslint.config.mjs eslint.config.cjs eslint.config.ts .eslintrc .eslintrc.js .eslintrc.cjs .eslintrc.json .eslintrc.yml .eslintrc.yaml \
   || grep -qs '"eslintConfig"' package.json; then
  emit eslint 'npx eslint . --max-warnings=0' 'npx eslint --max-warnings=0' '\.(js|jsx|mjs|cjs|ts|tsx|mts|cts)$'
fi
if [ -f tsconfig.json ]; then
  printf 'tsc\twhole project\tnpx tsc --noEmit\n'
fi
if has .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml .prettierrc.js .prettierrc.cjs .prettierrc.mjs prettier.config.js prettier.config.cjs prettier.config.mjs \
   || grep -qs '"prettier"[[:space:]]*:[[:space:]]*{' package.json; then
  emit prettier 'npx prettier --check .' 'npx prettier --check --ignore-unknown' '.'
fi
exit 0
