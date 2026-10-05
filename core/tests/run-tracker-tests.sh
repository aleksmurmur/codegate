#!/bin/bash
# Tests for tracker.py — the bridge between workflow events and the project's tracker adapter.
#
# Codegate knows no tracker, so these cases pin only the contract: when the adapter is
# called at all, which arguments it receives (the session's item filled in as --id), that a
# missing tracker degrades to "skipped", and that a broken adapter is reported, not
# swallowed.
#
#   core/tests/run-tracker-tests.sh          (from the cg-core checkout)
#
# Exits 0 if all assertions hold, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$SCRIPT_DIR/../shared/.claude/scripts" && pwd)"
PASS=0
FAIL=0
PY=$(command -v python3 || command -v python)

PROJECT=$(mktemp -d)
trap 'rm -rf "$PROJECT"' EXIT
mkdir -p "$PROJECT/.claude/scripts" "$PROJECT/.ai/sessions/s1"
cp "$SCRIPTS/tracker.py" "$PROJECT/.claude/scripts/"
CALLS="$PROJECT/adapter-calls.log"

manifest() { printf 'codegate_version: x\nstack: s\noptions:\n  tracker: %s\nfiles:\n' "$1" > "$PROJECT/.claude/codegate-installed.yml"; }

# An adapter that records its argv and answers per ADAPTER_MODE.
cat > "$PROJECT/.claude/tracker-adapter.py" <<'EOF'
import json, os, sys
with open(os.environ["CALLS"], "a", encoding="utf-8") as f:
    f.write(json.dumps(sys.argv[1:], ensure_ascii=False) + "\n")
mode = os.environ.get("ADAPTER_MODE", "ok")
if mode == "crash":
    raise RuntimeError("adapter exploded")
if mode == "error":
    print(json.dumps({"ok": False, "error": "tracker said no"})); sys.exit(1)
if mode == "noisy":
    print("debug: talking to the tracker")
print(json.dumps({"ok": True, "key": "X-1", "id": "1", "name": "Задача"}, ensure_ascii=False))
EOF

# run <args...> → sets OUT and CODE
run() {
    OUT=$(cd "$PROJECT" && CALLS="$CALLS" "$PY" .claude/scripts/tracker.py "$@" 2>/dev/null)
    CODE=$?
}
# expect <name> <want_code> <python predicate over j (parsed OUT) and calls (list of argv lists)>
expect() {
    local name="$1" want="$2" pred="$3" ok
    ok=$(OUT="$OUT" CALLS="$CALLS" "$PY" -c "
import json, os
j = json.loads(os.environ['OUT'])
p = os.environ['CALLS']
calls = [json.loads(l) for l in open(p, encoding='utf-8')] if os.path.exists(p) else []
print('yes' if ($pred) else 'no')" 2>/dev/null)
    if [ "$CODE" = "$want" ] && [ "$ok" = yes ]; then
        echo "PASS  $name"; PASS=$((PASS + 1))
    else
        echo "FAIL  $name  (exit=$CODE want=$want, out=$OUT)"; FAIL=$((FAIL + 1))
    fi
}

echo "-- no tracker: skipped, adapter never called --"
manifest none; rm -f "$CALLS"
run create --title t
expect "tracker=none is skipped"                0 "j['skipped'] and not calls"
rm -f "$PROJECT/.claude/codegate-installed.yml"
run create --title t
expect "no manifest means no tracker"           0 "j['skipped'] and not calls"
manifest some-tracker
run create --title t
expect "a tracker name is not an option value"  2 "'unknown tracker option' in j['error'] and not calls"
manifest adapter
mv "$PROJECT/.claude/tracker-adapter.py" "$PROJECT/adapter.bak"
run create --title t
expect "adapter option without adapter: skipped" 0 "j['skipped'] and 'tracker-adapter.py' in j['reason']"
mv "$PROJECT/adapter.bak" "$PROJECT/.claude/tracker-adapter.py"

echo ""
echo "-- what the adapter receives --"
rm -f "$CALLS"
run create --title "Починить чек" --type bugfix
expect "create passes its arguments verbatim"   0 "calls == [['create', '--title', 'Починить чек', '--type', 'bugfix']] and j['name'] == 'Задача'"
rm -f "$CALLS"
run get ABC-12
expect "get passes the key"                     0 "calls == [['get', 'ABC-12']]"
echo s1 > "$PROJECT/.ai/current-session"
printf '{"id":"item-42","key":"X-42"}' > "$PROJECT/.ai/sessions/s1/tracker.json"
rm -f "$CALLS"
run event pr_created
expect "event gets the session's item as --id"  0 "calls == [['event', 'pr_created', '--id', 'item-42']]"
rm -f "$CALLS"
run move "Code Review"
expect "move gets the session's item as --id"   0 "calls == [['move', 'Code Review', '--id', 'item-42']]"
rm -f "$CALLS"
run status --id item-9
expect "an explicit --id wins"                  0 "calls == [['status', '--id', 'item-9']]"
rm "$PROJECT/.ai/current-session"
rm -f "$CALLS"
run event started
expect "no session item: error, adapter unused" 1 "not j['ok'] and not calls"
rm -f "$CALLS"
OUT=$(cd "$PROJECT" && CALLS="$CALLS" "$PY" .claude/scripts/tracker.py event finished 2>/dev/null); CODE=$?
if [ "$CODE" = 2 ] && [ ! -f "$CALLS" ]; then
    echo "PASS  unknown event is rejected before the adapter"; PASS=$((PASS + 1))
else
    echo "FAIL  unknown event is rejected before the adapter (exit=$CODE)"; FAIL=$((FAIL + 1))
fi

echo ""
echo "-- what comes back --"
OUT=$(cd "$PROJECT" && CALLS="$CALLS" ADAPTER_MODE=error "$PY" .claude/scripts/tracker.py check 2>/dev/null); CODE=$?
expect "adapter error passes through"           1 "j == {'ok': False, 'error': 'tracker said no'}"
OUT=$(cd "$PROJECT" && CALLS="$CALLS" ADAPTER_MODE=crash "$PY" .claude/scripts/tracker.py check 2>/dev/null); CODE=$?
expect "a crash is reported with its cause"     1 "not j['ok'] and 'adapter exploded' in j['error']"
OUT=$(cd "$PROJECT" && CALLS="$CALLS" ADAPTER_MODE=noisy "$PY" .claude/scripts/tracker.py check 2>/dev/null); CODE=$?
expect "stray output: the last line is the reply" 0 "j['ok'] and j['key'] == 'X-1'"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
