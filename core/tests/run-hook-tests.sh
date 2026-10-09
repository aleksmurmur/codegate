#!/bin/bash
# Tests for pre-write.sh — the hook that decides whether the agent may write a file.
#
# The hook is handed an ABSOLUTE path by Claude Code, and on Windows that path uses
# backslashes. Every allowlist in the hook is a glob over forward slashes, so before the
# normalization fix a Windows agent could not write its own session files: `.ai/PLAN.md`
# arrived as `D:\project\.ai\PLAN.md`, matched nothing, fell through to the state check and
# was blocked. These cases pin both separator styles so the hook cannot regress on one
# platform while passing on another.
#
#   core/tests/run-hook-tests.sh          (from the cg-core checkout)
#
# Exits 0 if all assertions hold, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(cd "$SCRIPT_DIR/../shared/.claude/hooks" && pwd)/pre-write.sh"
PASS=0
FAIL=0

[ -f "$HOOK" ] || { echo "ERROR: pre-write.sh not found at $HOOK"; exit 2; }

PROJECT=$(mktemp -d)
trap 'rm -rf "$PROJECT"' EXIT
mkdir -p "$PROJECT/.ai/sessions/s1" "$PROJECT/.claude/hooks" "$PROJECT/src"

# check <name> <file-path> <want_exit>
check() {
    local name="$1" path="$2" want="$3"
    local got
    printf '{"tool_input":{"file_path":"%s"}}' "$(printf '%s' "$path" | sed 's/\\/\\\\/g')" \
        | ( cd "$PROJECT" && bash "$HOOK" >/dev/null 2>&1 )
    got=$?
    if [ "$got" = "$want" ]; then
        echo "PASS  $name"; PASS=$((PASS + 1))
    else
        echo "FAIL  $name  (want exit=$want, got exit=$got)"; FAIL=$((FAIL + 1))
    fi
}

# ── with no session at all, only the allowlists may pass ────────────────────────────────
echo "-- no active session --"
check "relative .ai/ is allowed"            ".ai/sessions/s1/PLAN.md"            0
check "posix absolute .ai/ is allowed"      "$PROJECT/.ai/sessions/s1/PLAN.md"   0
check "windows absolute .ai/ is allowed"    'D:\project\.ai\sessions\s1\PLAN.md' 0
check "windows forward .ai/ is allowed"     'D:/project/.ai/sessions/s1/PLAN.md' 0
check "relative .claude/ is allowed"        ".claude/hooks/pre-write.sh"         0
check "windows absolute .claude/ allowed"   'D:\project\.claude\settings.json'   0
check "CLAUDE.md at the root is allowed"    "CLAUDE.md"                          0
check "windows absolute CLAUDE.md allowed"  'D:\project\CLAUDE.md'               0
check "windows absolute .gitignore allowed" 'D:\project\.gitignore'              0
check "a source file is blocked"            "src/Main.kt"                        2
check "windows absolute source is blocked"  'D:\project\src\Main.kt'             2

# a directory merely ENDING in .ai is not the session directory
check "a dir ending in .ai is not .ai/"     "src/vendor.ai/Main.kt"              2

# ── with a session, the state decides for source files ──────────────────────────────────
echo ""
echo "-- session in ELICITED --"
echo "s1" > "$PROJECT/.ai/current-session"
echo "ELICITED" > "$PROJECT/.ai/sessions/s1/state"
check "source blocked while ELICITED"       "src/Main.kt"                        2
check ".ai/ still allowed while ELICITED"   'D:\project\.ai\sessions\s1\PLAN.md' 0

echo ""
echo "-- session in IMPLEMENTING --"
echo "IMPLEMENTING" > "$PROJECT/.ai/sessions/s1/state"
check "source allowed while IMPLEMENTING"   "src/Main.kt"                        0
check "windows source allowed too"          'D:\project\src\Main.kt'             0

# ── the reason reaches the agent: Claude Code shows only stderr for exit 2 ────────────────
echo ""
echo "-- blocking reason on stderr --"
rm -f "$PROJECT/.ai/current-session"
ERR=$(printf '{"tool_input":{"file_path":"src/Main.kt"}}' | ( cd "$PROJECT" && bash "$HOOK" 2>&1 >/dev/null ))
if [ -n "$ERR" ]; then echo "PASS  block reason goes to stderr"; PASS=$((PASS + 1))
else echo "FAIL  block reason goes to stderr  (stderr was empty)"; FAIL=$((FAIL + 1)); fi

# ── the hook guards this repository only: files elsewhere are not its business ────────────
echo ""
echo "-- inside a git repository --"
REPO=$(mktemp -d)
OTHER=$(mktemp -d)
trap 'rm -rf "$PROJECT" "$REPO" "$OTHER"' EXIT
git -C "$REPO" init -q
mkdir -p "$REPO/.ai/sessions/s1" "$REPO/src"
echo "s1" > "$REPO/.ai/current-session"
echo "ELICITED" > "$REPO/.ai/sessions/s1/state"
REPO_ABS=$(cd "$REPO" && pwd -W 2>/dev/null || pwd)
OTHER_ABS=$(cd "$OTHER" && pwd -W 2>/dev/null || pwd)

# check_in <name> <file-path> <want_exit> — like check, but run from the git repository
check_in() {
    local name="$1" path="$2" want="$3" got
    printf '{"tool_input":{"file_path":"%s"}}' "$path" | ( cd "$REPO" && bash "$HOOK" >/dev/null 2>&1 )
    got=$?
    if [ "$got" = "$want" ]; then
        echo "PASS  $name"; PASS=$((PASS + 1))
    else
        echo "FAIL  $name  (want exit=$want, got exit=$got)"; FAIL=$((FAIL + 1))
    fi
}
check_in "relative source still blocked"        "src/Main.kt"                     2
check_in "absolute source in repo blocked"      "$REPO_ABS/src/Main.kt"           2
check_in "file in another directory allowed"    "$OTHER_ABS/report.md"            0
check_in "new file in a new dir elsewhere"      "$OTHER_ABS/deep/new/report.md"   0
# Claude Code on Windows sends D:\dir\file: the comparison must not depend on the spelling
case "$OTHER_ABS" in
  ?:/*)
    WIN_OTHER=$(python3 -c "import sys; print(sys.argv[1].replace('/', chr(92)))" "$OTHER_ABS/report.md")
    WIN_SRC=$(python3 -c "import sys; print(sys.argv[1].replace('/', chr(92)))" "$REPO_ABS/src/Main.kt")
    for case_ in "other:$WIN_OTHER:0" "src:$WIN_SRC:2"; do
      p_=${case_#*:}; want_=${p_##*:}; p_=${p_%:*}
      json_=$(python3 -c "import json,sys; print(json.dumps({'tool_input': {'file_path': sys.argv[1]}}))" "$p_")
      printf "%s" "$json_" | ( cd "$REPO" && bash "$HOOK" >/dev/null 2>&1 ); got_=$?
      if [ "$got_" = "$want_" ]; then echo "PASS  windows backslash path (${case_%%:*})"; PASS=$((PASS + 1))
      else echo "FAIL  windows backslash path (${case_%%:*})  (want exit=$want_, got exit=$got_)"; FAIL=$((FAIL + 1)); fi
    done
    ;;
esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
