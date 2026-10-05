#!/bin/bash
# Tests for tracker.py — the bridge between workflow events and an issue tracker.
#
# A fake Plane API runs on localhost and records every request, so the cases pin what
# is actually sent: the state an event maps to, the item a session points at, and that
# a missing tracker or token degrades to "skipped" instead of failing the workflow.
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
FAKE_HOME=$(mktemp -d)
SERVER_PID=
trap '[ -n "$SERVER_PID" ] && kill $SERVER_PID 2>/dev/null; rm -rf "$PROJECT" "$FAKE_HOME"' EXIT

mkdir -p "$PROJECT/.claude/scripts" "$PROJECT/.ai/sessions/s1"
cp "$SCRIPTS/tracker.py" "$SCRIPTS/cg-option.sh" "$PROJECT/.claude/scripts/"

# ── fake Plane ──────────────────────────────────────────────────────────────────────────
cat > "$PROJECT/fake_plane.py" <<'EOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[2]
STATES = [{"id": "st-work", "name": "В работе"}, {"id": "st-qa", "name": "в QA"}]
FAIL_CREATE = {"on": False}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def _record(self, body):
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps({"m": self.command, "p": self.path, "key": self.headers.get("X-API-Key"), "b": body}, ensure_ascii=False) + "\n")
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n).decode()) if n else None
    def do_GET(self):
        self._record(None)
        if self.path.endswith("/states/"): return self._send(200, {"results": STATES})
        return self._send(200, {"id": self.path.rstrip("/").split("/")[-1], "sequence_id": 7, "name": "x"})
    def do_POST(self):
        b = self._body(); self._record(b)
        if b and b.get("name") == "boom": return self._send(500, {"detail": "down"})
        return self._send(201, {"id": "item-1", "sequence_id": 7, "name": b["name"]})
    def do_PATCH(self):
        b = self._body(); self._record(b)
        return self._send(200, {"id": self.path.rstrip("/").split("/")[-1], "sequence_id": 7, "name": "x"})

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
PORT=$("$PY" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
LOG="$PROJECT/requests.log"
"$PY" "$PROJECT/fake_plane.py" "$PORT" "$LOG" &
SERVER_PID=$!
for _ in $(seq 1 50); do "$PY" -c "import socket; socket.create_connection(('127.0.0.1',$PORT),0.2)" 2>/dev/null && break; sleep 0.1; done

manifest() { printf 'codegate_version: x\nstack: s\noptions:\n  tracker: %s\nfiles:\n' "$1" > "$PROJECT/.claude/codegate-installed.yml"; }
plane_config() {
    printf '{"base_url":"http://127.0.0.1:%s","workspace":"ws","project_id":"proj","identifier":"BACK","events":{"started":"В работе","pr_created":"в QA"}}' "$PORT" \
        > "$PROJECT/.claude/tracker.json"
}

# run <args...> → sets OUT and CODE
run() {
    OUT=$(cd "$PROJECT" && HOME="$FAKE_HOME" USERPROFILE="$FAKE_HOME" "$PY" .claude/scripts/tracker.py "$@" 2>/dev/null)
    CODE=$?
}
# expect <name> <want_code> <python predicate over j (parsed OUT) and log (list of requests)>
expect() {
    local name="$1" want="$2" pred="$3" ok
    ok=$(OUT="$OUT" LOG="$LOG" "$PY" -c "
import json, os
j = json.loads(os.environ['OUT'])
log = [json.loads(l) for l in open(os.environ['LOG'], encoding='utf-8')] if os.path.exists(os.environ['LOG']) else []
print('yes' if ($pred) else 'no')" 2>/dev/null)
    if [ "$CODE" = "$want" ] && [ "$ok" = yes ]; then
        echo "PASS  $name"; PASS=$((PASS + 1))
    else
        echo "FAIL  $name  (exit=$CODE want=$want, out=$OUT)"; FAIL=$((FAIL + 1))
    fi
}

echo "-- tracker off or unconfigured: skipped, never an error --"
manifest none
run create --title t
expect "tracker=none is skipped"              0 "j['skipped'] and not j['ok']"
rm -f "$PROJECT/.claude/codegate-installed.yml"
run create --title t
expect "no manifest means no tracker"         0 "j['skipped']"
manifest plane
run create --title t
expect "plane without config is skipped"      0 "j['skipped'] and 'tracker.json' in j['reason']"
plane_config
run create --title t
expect "plane without a token is skipped"     0 "j['skipped'] and 'token' in j['reason']"

echo ""
echo "-- plane --"
mkdir -p "$FAKE_HOME/.claude"
printf 'PLANE_API_KEY=secret-1
' > "$FAKE_HOME/.claude/plane.env"
rm -f "$LOG"
run create --title "Add login" --description $'first line\nsecond\n\nnext paragraph' --type feature
expect "create returns key and id"            0 "j['ok'] and j['key'] == 'BACK-7' and j['id'] == 'item-1'"
expect "create lands in the started state"    0 "[r['b']['state'] for r in log if r['m'] == 'POST'] == ['st-work']"
expect "token from plane.env is sent"         0 "log and all(r['key'] == 'secret-1' for r in log)"
expect "description keeps its paragraphs"     0 "[r['b']['description_html'] for r in log if r['m'] == 'POST'] == ['<p>first line<br>second</p><p>next paragraph</p>']"
expect "create writes no session file"        0 "not os.path.exists('$PROJECT/.ai/sessions/s1/tracker.json')"

echo s1 > "$PROJECT/.ai/current-session"
printf '{"id":"item-42","key":"BACK-42"}' > "$PROJECT/.ai/sessions/s1/tracker.json"
rm -f "$LOG"
run event pr_created
expect "event moves the session's item"       0 "[(r['p'].split('/')[-2], r['b']) for r in log if r['m'] == 'PATCH'] == [('item-42', {'state': 'st-qa'})]"
rm -f "$LOG"
run event pr_created --id item-9
expect "--id wins over the session"           0 "[r['p'].split('/')[-2] for r in log if r['m'] == 'PATCH'] == ['item-9']"
"$PY" - "$PROJECT/.claude/tracker.json" <<'EOF'
import json, sys
p = sys.argv[1]; c = json.load(open(p, encoding="utf-8")); del c["events"]["pr_created"]
json.dump(c, open(p, "w", encoding="utf-8"), ensure_ascii=False)
EOF
rm -f "$LOG"
run event pr_created
expect "unmapped event is skipped, no PATCH"  0 "j['skipped'] and 'pr_created' in j['reason'] and not any(r['m'] == 'PATCH' for r in log)"
plane_config
run move "No such state"
expect "unknown state is an error"            1 "not j['ok'] and 'No such state' in j['error']"
run create --title boom
expect "tracker failure is an error"          1 "not j['ok'] and 'down' in j['error']"
rm "$PROJECT/.ai/current-session"
run status
expect "no session item and no --id: error"   1 "not j['ok']"
rm -f "$LOG"
OUT=$(cd "$PROJECT" && HOME="$FAKE_HOME" PLANE_API_KEY=from-env "$PY" .claude/scripts/tracker.py status --id item-5 2>/dev/null); CODE=$?
expect "PLANE_API_KEY env beats plane.env"    0 "j['ok'] and log and all(r['key'] == 'from-env' for r in log)"

run check
expect "check passes when events map"         0 "j['ok'] and 'в QA' in j['states'] and j['missing'] == {}"
"$PY" - "$PROJECT/.claude/tracker.json" <<'EOF2'
import json, sys
p = sys.argv[1]; c = json.load(open(p, encoding="utf-8")); c["events"]["pr_created"] = "Ревью"
json.dump(c, open(p, "w", encoding="utf-8"), ensure_ascii=False)
EOF2
run check
expect "check flags an unmapped state"        1 "not j['ok'] and j['missing'] == {'pr_created': 'Ревью'}"
plane_config

echo ""
echo "-- custom adapter --"
manifest custom
run create --title t
expect "custom without adapter is skipped"    0 "j['skipped']"
cat > "$PROJECT/.claude/tracker-adapter.py" <<'EOF2'
import json, sys
print(json.dumps({"ok": True, "key": "X-1", "id": "1", "args": " ".join(sys.argv[1:])}))
EOF2
run create --title t --type bugfix
expect "custom adapter gets the same args"    0 "j['key'] == 'X-1' and j['args'] == 'create --title t --type bugfix'"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
