#!/usr/bin/env python3
"""Issue-tracker bridge for the codegate workflow.

The workflow speaks in events, never in a tracker's own states:
  started     — a task began (Phase 0); the item is created in this state
  pr_created  — its PR/MR exists (Phase 5)
Which tracker, and which of its states each event means, is project config.

Usage:
  tracker.py create --title T [--description D] [--type feature|bugfix|refactor]
  tracker.py event  <started|pr_created> [--id ID]
  tracker.py move   <tracker state name> [--id ID]
  tracker.py status [--id ID]
  tracker.py check                  verify config and token: lists the tracker's states,
                                    flags events mapped to a state that does not exist

Without --id, `event`/`move`/`status` use the current session's item
(`.ai/sessions/<current>/tracker.json`, written by the workflow in Phase 1).
`create` never writes session files: in Phase 0 the new session does not exist yet.

Output: exactly one JSON line on stdout.
  {"ok": true, "key": "ABC-12", "id": "...", "url": "...", ...}
  {"ok": false, "skipped": true, "reason": "..."}   tracker off or not configured
  {"ok": false, "error": "..."}                     the tracker refused or is unreachable
Exit codes: 0 ok or skipped; 1 error; 2 bad usage or broken config.

Which tracker: `.claude/scripts/cg-option.sh tracker` (none | plane | custom).
  plane  — config in .claude/tracker.json (no secrets), token in PLANE_API_KEY or
           ~/.claude/plane.env.
  custom — .claude/tracker-adapter.py, a Python script run with this same interpreter;
           it takes these same arguments and honours this same output contract.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

CONFIG = Path(".claude/tracker.json")
CUSTOM_ADAPTER = Path(".claude/tracker-adapter.py")
EVENTS = ("started", "pr_created")


def emit(obj: dict, code: int = 0) -> None:
    print(json.dumps(obj, ensure_ascii=False))
    sys.exit(code)


def skipped(reason: str) -> None:
    emit({"ok": False, "skipped": True, "reason": reason})


def tracker_kind() -> str:
    # Same lookup as cg-option.sh, done here: `bash` from Python on Windows may resolve to WSL.
    manifest = Path(os.environ.get("CG_MANIFEST", ".claude/codegate-installed.yml"))
    if not manifest.exists():
        return "none"
    in_options = False
    for line in manifest.read_text(encoding="utf-8").splitlines():
        if line.rstrip() == "options:":
            in_options = True
        elif in_options and line[:1] not in (" ", ""):
            break
        elif in_options and line.strip().startswith("tracker:"):
            return line.split(":", 1)[1].strip() or "none"
    return "none"


def session_item_id() -> str | None:
    cur = Path(".ai/current-session")
    if not cur.exists():
        return None
    item = Path(".ai/sessions") / cur.read_text(encoding="utf-8").strip() / "tracker.json"
    if not item.exists():
        return None
    try:
        return json.loads(item.read_text(encoding="utf-8")).get("id")
    except (ValueError, OSError):
        return None


# ── Plane ──────────────────────────────────────────────────────────────────────────────


def plane_token() -> str | None:
    token = os.environ.get("PLANE_API_KEY")
    if token:
        return token.strip()
    env = Path.home() / ".claude" / "plane.env"
    if env.exists():
        for line in env.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("PLANE_API_KEY="):
                value = line.split("=", 1)[1].strip().strip('"').strip("'")
                if value and value != "PASTE_YOUR_TOKEN_HERE":
                    return value
    return None


class Plane:
    def __init__(self, cfg: dict, token: str):
        self.base = cfg["base_url"].rstrip("/")
        self.workspace = cfg["workspace"]
        self.project = cfg["project_id"]
        self.identifier = cfg.get("identifier", "")
        self.events = cfg.get("events", {})
        self.token = token

    def call(self, method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
        url = f"{self.base}/api/v1/workspaces/{self.workspace}/projects/{self.project}{path}"
        req = urllib.request.Request(
            url, data=json.dumps(body).encode() if body is not None else None, method=method
        )
        req.add_header("X-API-Key", self.token)
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode()
                return resp.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            return e.code, {"error": e.read().decode()[:600]}
        except Exception as e:  # noqa: BLE001 — network/TLS errors go back as JSON, not a trace
            return 0, {"error": f"{type(e).__name__}: {e}"}

    def state_id(self, name: str) -> str | None:
        status, data = self.call("GET", "/states/")
        if status != 200:
            return None
        wanted = name.strip().lower()
        for s in data.get("results", []):
            if s["name"].strip().lower() == wanted:
                return s["id"]
        return None

    def item(self, data: dict) -> dict:
        seq = data.get("sequence_id")
        return {
            "ok": True,
            "id": data["id"],
            "key": f"{self.identifier}-{seq}" if self.identifier and seq is not None else str(seq),
            "name": data.get("name"),
            "url": f"{self.base}/{self.workspace}/projects/{self.project}/issues/{data['id']}",
        }

    def create(self, title: str, description: str | None) -> None:
        body: dict = {"name": title.strip()[:240]}
        started = self.events.get("started")
        if started:
            sid = self.state_id(started)
            if not sid:
                emit({"ok": False, "error": f"state not found in Plane: {started}"}, 1)
            body["state"] = sid
        if description:
            paragraphs = [p.strip() for p in description.strip().split("\n\n") if p.strip()]
            body["description_html"] = "".join(
                "<p>" + html.escape(p).replace("\n", "<br>") + "</p>" for p in paragraphs
            )
        status, data = self.call("POST", "/issues/", body)
        if status not in (200, 201):
            emit({"ok": False, "error": data.get("error", f"http {status}")}, 1)
        emit(self.item(data))

    def move(self, item_id: str, state_name: str) -> None:
        sid = self.state_id(state_name)
        if not sid:
            emit({"ok": False, "error": f"state not found in Plane: {state_name}"}, 1)
        status, data = self.call("PATCH", f"/issues/{item_id}/", {"state": sid})
        if status not in (200, 201):
            emit({"ok": False, "error": data.get("error", f"http {status}")}, 1)
        emit({**self.item(data), "state": state_name})

    def check(self) -> None:
        status, data = self.call("GET", "/states/")
        if status != 200:
            emit({"ok": False, "error": data.get("error", f"http {status}")}, 1)
        names = [s["name"] for s in data.get("results", [])]
        known = {n.strip().lower() for n in names}
        missing = {e: n for e, n in self.events.items() if n.strip().lower() not in known}
        emit({"ok": not missing, "states": names, "missing": missing}, 0 if not missing else 1)

    def status(self, item_id: str) -> None:
        status, data = self.call("GET", f"/issues/{item_id}/")
        if status != 200:
            emit({"ok": False, "error": data.get("error", f"http {status}")}, 1)
        emit(self.item(data))


def load_plane() -> Plane:
    if not CONFIG.exists():
        skipped(f"tracker=plane but {CONFIG} is missing — re-run /cg-start to configure it")
    try:
        cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
        for key in ("base_url", "workspace", "project_id"):
            if not cfg.get(key):
                raise KeyError(key)
    except (ValueError, KeyError) as e:
        emit({"ok": False, "error": f"{CONFIG} is invalid: {e}"}, 2)
    token = plane_token()
    if not token:
        skipped("Plane token not set: PLANE_API_KEY or ~/.claude/plane.env")
    return Plane(cfg, token)


# ── dispatch ───────────────────────────────────────────────────────────────────────────


def parse(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="codegate issue-tracker bridge")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create")
    c.add_argument("--title", required=True)
    c.add_argument("--description")
    c.add_argument("--type", choices=["feature", "bugfix", "refactor"])
    e = sub.add_parser("event")
    e.add_argument("name", choices=EVENTS)
    e.add_argument("--id")
    m = sub.add_parser("move")
    m.add_argument("state")
    m.add_argument("--id")
    s = sub.add_parser("status")
    s.add_argument("--id")
    sub.add_parser("check")
    return p.parse_args(argv)


def main(argv: list[str]) -> None:
    # Tracker state names are often non-ASCII; the console code page on Windows would mangle them.
    sys.stdout.reconfigure(encoding="utf-8")
    args = parse(argv)
    kind = tracker_kind()

    if kind == "none":
        skipped("no tracker configured (option tracker=none)")
    if kind == "custom":
        if not CUSTOM_ADAPTER.exists():
            skipped(f"tracker=custom but {CUSTOM_ADAPTER} is missing")
        result = subprocess.run(
            [sys.executable, str(CUSTOM_ADAPTER), *argv], capture_output=True, text=True,
            encoding="utf-8", env={**os.environ, "PYTHONIOENCODING": "utf-8"},
        )
        sys.stdout.write(result.stdout)
        sys.exit(result.returncode)
    if kind != "plane":
        emit({"ok": False, "error": f"unknown tracker: {kind}"}, 2)

    plane = load_plane()
    if args.cmd == "check":
        plane.check()
    if args.cmd == "create":
        plane.create(args.title, args.description)

    item_id = args.id or session_item_id()
    if not item_id:
        emit({"ok": False, "error": "no tracker item for this session (pass --id)"}, 1)
    if args.cmd == "event":
        state = plane.events.get(args.name)
        if not state:
            skipped(f"no Plane state mapped to event '{args.name}' in {CONFIG}")
        plane.move(item_id, state)
    if args.cmd == "move":
        plane.move(item_id, args.state)
    plane.status(item_id)


if __name__ == "__main__":
    main(sys.argv[1:])
