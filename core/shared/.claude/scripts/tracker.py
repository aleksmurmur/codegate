#!/usr/bin/env python3
"""Issue-tracker bridge for the codegate workflow.

The workflow speaks in events, never in a tracker's own states:
  started     — a task began (Phase 0); the item is created in this state
  pr_created  — its PR/MR exists (Phase 5)
Which tracker, and which of its states each event means, is project config.

Usage:
  tracker.py create --title T [--description D] [--type feature|bugfix|refactor]
  tracker.py get    <KEY>           an existing item by its key (e.g. ABC-12): title,
                                    plain-text description, state — to start a task from it
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
      `get` adds "description" (plain text) and "state" (the tracker's state name).
  {"ok": false, "skipped": true, "reason": "..."}   tracker off or not configured
  {"ok": false, "error": "..."}                     the tracker refused or is unreachable
Exit codes: 0 ok or skipped; 1 error; 2 bad usage or broken config.

Which tracker: `.claude/scripts/cg-option.sh tracker` (none | plane | custom).
  plane  — config in .claude/tracker.json (no secrets); per developer, in the environment
           or ~/.claude/plane.env: PLANE_API_KEY (a personal token — items are created in
           its owner's name) and optional PLANE_ASSIGNEE (email or display name), set as
           assignee on `create` and added on `event started`.
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
from html.parser import HTMLParser
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


class _Text(HTMLParser):
    BLOCKS = {"p", "div", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "tr"}

    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in self.BLOCKS:
            self.parts.append("\n")
        if tag == "li":
            self.parts.append("- ")

    def handle_data(self, data: str) -> None:
        self.parts.append(data)


def html_to_text(markup: str | None) -> str:
    parser = _Text()
    parser.feed(markup or "")
    text = "\n".join(line.rstrip() for line in "".join(parser.parts).splitlines())
    while "\n\n\n" in text:
        text = text.replace("\n\n\n", "\n\n")
    return text.strip()


# ── Plane ──────────────────────────────────────────────────────────────────────────────


def plane_setting(name: str) -> str | None:
    """A per-developer Plane setting: the environment first, then ~/.claude/plane.env."""
    value = os.environ.get(name)
    if value:
        return value.strip()
    env = Path.home() / ".claude" / "plane.env"
    if env.exists():
        for line in env.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith(f"{name}="):
                value = line.split("=", 1)[1].strip().strip('"').strip("'")
                if value and value != "PASTE_YOUR_TOKEN_HERE":
                    return value
    return None


def plane_token() -> str | None:
    return plane_setting("PLANE_API_KEY")


class Plane:
    def __init__(self, cfg: dict, token: str):
        self.base = cfg["base_url"].rstrip("/")
        self.workspace = cfg["workspace"]
        self.project = cfg["project_id"]
        self.identifier = cfg.get("identifier", "")
        self.events = cfg.get("events", {})
        self.token = token
        # Plane never assigns the creator; whom to assign is per developer, so it lives next
        # to the token (PLANE_ASSIGNEE = email or display name), not in the committed config.
        self.assignee = plane_setting("PLANE_ASSIGNEE")

    def call(self, method: str, path: str, body: dict | None = None, project: bool = True) -> tuple[int, dict]:
        scope = f"/projects/{self.project}" if project else ""
        url = f"{self.base}/api/v1/workspaces/{self.workspace}{scope}{path}"
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
            emit({"ok": False, "error": f"cannot list Plane states: {data.get('error', f'http {status}')}"}, 1)
        wanted = name.strip().lower()
        for s in data.get("results", []):
            if s["name"].strip().lower() == wanted:
                return s["id"]
        return None

    def assignee_id(self) -> tuple[str | None, str | None]:
        """(member id, warning). A missing or unknown assignee never fails the call."""
        if not self.assignee:
            return None, None
        status, data = self.call("GET", "/members/")
        if status != 200:
            return None, f"cannot list Plane members: {data.get('error', f'http {status}')}"
        rows = data if isinstance(data, list) else data.get("results", [])
        wanted = self.assignee.strip().lower()
        for m in rows:
            if wanted in ((m.get("email") or "").lower(), (m.get("display_name") or "").lower()):
                return m["id"], None
        return None, f"PLANE_ASSIGNEE '{self.assignee}' is not a member of the project"

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
        member, warning = self.assignee_id()
        if member:
            body["assignees"] = [member]
        status, data = self.call("POST", "/issues/", body)
        if status not in (200, 201):
            emit({"ok": False, "error": data.get("error", f"http {status}")}, 1)
        emit({**self.item(data), **({"warning": warning} if warning else {})})

    def move(self, item_id: str, state_name: str, assign: bool = False) -> None:
        sid = self.state_id(state_name)
        if not sid:
            emit({"ok": False, "error": f"state not found in Plane: {state_name}"}, 1)
        body: dict = {"state": sid}
        warning = None
        if assign:
            # Taking up an existing item: add the developer, keep whoever is already on it.
            member, warning = self.assignee_id()
            if member:
                current = self.call("GET", f"/issues/{item_id}/")[1].get("assignees") or []
                if member not in current:
                    body["assignees"] = [*current, member]
        status, data = self.call("PATCH", f"/issues/{item_id}/", body)
        if status not in (200, 201):
            emit({"ok": False, "error": data.get("error", f"http {status}")}, 1)
        emit({**self.item(data), "state": state_name, **({"warning": warning} if warning else {})})

    def get(self, key: str) -> None:
        # Plane resolves "<IDENTIFIER>-<seq>" only at workspace level, not under /projects/.
        status, data = self.call("GET", f"/issues/{key.strip().upper()}/", project=False)
        if status == 404:
            emit({"ok": False, "error": f"no item {key} in Plane"}, 1)
        if status != 200:
            emit({"ok": False, "error": data.get("error", f"http {status}")}, 1)
        if data.get("project") != self.project:
            emit({"ok": False, "error": f"{key} belongs to another Plane project"}, 1)
        states = self.call("GET", "/states/")[1].get("results", [])
        state = next((s["name"] for s in states if s["id"] == data.get("state")), data.get("state"))
        emit({**self.item(data), "description": html_to_text(data.get("description_html")), "state": state})

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
    g = sub.add_parser("get")
    g.add_argument("key")
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
    if args.cmd == "get":
        plane.get(args.key)

    item_id = args.id or session_item_id()
    if not item_id:
        emit({"ok": False, "error": "no tracker item for this session (pass --id)"}, 1)
    if args.cmd == "event":
        state = plane.events.get(args.name)
        if not state:
            skipped(f"no Plane state mapped to event '{args.name}' in {CONFIG}")
        plane.move(item_id, state, assign=args.name == "started")
    if args.cmd == "move":
        plane.move(item_id, args.state)
    plane.status(item_id)


if __name__ == "__main__":
    main(sys.argv[1:])
