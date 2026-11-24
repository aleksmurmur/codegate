#!/usr/bin/env bash
# The linters this project has configured, as `name<TAB>command` lines, check mode only.
# Read by gate-checks.sh; run from the project root.

gradle_has() { grep -qs "$1" build.gradle.kts build.gradle; }
GRADLE=./gradlew
[ -x "$GRADLE" ] || GRADLE=gradle

if gradle_has ktlint; then
  printf 'ktlint\t%s ktlintCheck\n' "$GRADLE"
elif grep -qs '^\[\*\.{kt,kts}\]' .editorconfig && command -v ktlint >/dev/null 2>&1; then
  printf 'ktlint\tktlint --reporter=plain\n'
fi
if [ -f detekt.yml ] || [ -f detekt.yaml ] || gradle_has detekt; then
  printf 'detekt\t%s detekt\n' "$GRADLE"
fi
if [ -f checkstyle.xml ] || [ -f config/checkstyle/checkstyle.xml ]; then
  printf 'checkstyle\t%s checkstyleMain\n' "$GRADLE"
fi
exit 0
