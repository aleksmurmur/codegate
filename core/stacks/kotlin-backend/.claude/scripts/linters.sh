#!/usr/bin/env bash
# The linters this project has configured, as `name<TAB>scope<TAB>command` lines, check mode
# only. Read by gate-checks.sh, which sets CG_BASE and CG_CHANGED_FILES; run from the project root.
# A plugin is found by its id or artifact in any Gradle build file (root, subprojects, buildSrc,
# build-logic, the version catalog), so a mere mention of a tool's name does not count.

GRADLE_FILES=$(find . -maxdepth 6 \( -name .git -o -name build -o -name .gradle -o -name node_modules \) -prune -o \
  -type f \( -name '*.gradle' -o -name '*.gradle.kts' -o -name '*.versions.toml' \
             -o \( -name '*.kt' \( -path './buildSrc/*' -o -path './build-logic/*' \) \) \) -print 2>/dev/null)
gradle_has() {
  printf '%s\n' "$GRADLE_FILES" | { while IFS= read -r f; do [ -n "$f" ] && grep -qsE "$1" "$f" && exit 0; done; exit 1; }
}
pom_has() { grep -qs "$1" pom.xml; }

# The changed Kotlin files, shell-quoted, for tools that take files; empty without a base.
changed_kotlin() {
  printf '%s\n' "${CG_CHANGED_FILES-}" | grep -E '\.kts?$' | while IFS= read -r f; do printf ' %q' "$f"; done
}

if [ -n "$GRADLE_FILES" ]; then
  GRADLE=./gradlew
  [ -x "$GRADLE" ] || GRADLE=gradle
  if gradle_has 'org\.jlleitschuh\.gradle'; then
    printf 'ktlint\twhole project\t%s ktlintCheck\n' "$GRADLE"
  elif gradle_has 'org\.jmailen'; then
    printf 'kotlinter\twhole project\t%s lintKotlin\n' "$GRADLE"
  fi
  gradle_has 'com\.diffplug\.spotless' && printf 'spotless\twhole project\t%s spotlessCheck\n' "$GRADLE"
  gradle_has 'io\.gitlab\.arturbosch\.detekt|dev\.detekt' && printf 'detekt\twhole project\t%s detekt\n' "$GRADLE"
  gradle_has "(id|plugin)[[:space:](=:]*[\"']checkstyle[\"']|\`checkstyle\`" \
    && printf 'checkstyle\twhole project\t%s checkstyleMain\n' "$GRADLE"
elif [ -f pom.xml ]; then
  MVN=./mvnw
  [ -x "$MVN" ] || MVN=mvn
  pom_has ktlint-maven-plugin && printf 'ktlint\twhole project\t%s -q ktlint:check\n' "$MVN"
  pom_has spotless-maven-plugin && printf 'spotless\twhole project\t%s -q spotless:check\n' "$MVN"
  pom_has detekt-maven-plugin && printf 'detekt\twhole project\t%s -q detekt:check\n' "$MVN"
  pom_has maven-checkstyle-plugin && printf 'checkstyle\twhole project\t%s -q checkstyle:check\n' "$MVN"
fi

# No build-tool ktlint, but the CLI and an .editorconfig for Kotlin: lint the changed files.
if ! gradle_has 'org\.jlleitschuh\.gradle|org\.jmailen' && ! pom_has ktlint-maven-plugin \
   && grep -qs '^\[\*\.{kt,kts}\]' .editorconfig && command -v ktlint >/dev/null 2>&1; then
  if [ -z "${CG_BASE-}" ]; then
    printf 'ktlint\twhole project\tktlint --reporter=plain\n'
  else
    files=$(changed_kotlin)
    [ -n "$files" ] && printf 'ktlint\tchanged files\tktlint --reporter=plain%s\n' "$files"
  fi
fi
exit 0
