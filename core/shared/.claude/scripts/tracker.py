#!/usr/bin/env python3
"""Issue-tracker bridge for the codegate workflow.

Codegate knows no tracker. It reports events; the project's adapter decides what
they mean in its tracker:
  started     — a task began (Phase 0): an item is created, or an existing one taken up
  pr_created  — its PR/MR exists (Phase 5)

Usage:
  tracker.py create --title T [--description D] [--type feature|bugfix|refactor]
  tracker.py get    <KEY>           an existing item: title, plain-text description, state
  tracker.py event  <started|pr_created> [--id ID]
  tracker.py move   <tracker state name> [--id ID]
  tracker.py status [--id ID]
  tracker.py check                  verify the adapter's config and credentials

Without --id, `event`/`move`/`status` use the current session's item
(`.ai/sessions/<current>/tracker.json`, written by the workflow in Phase 1); the
adapter always receives an explicit --id. `create` never writes session files: in
Phase 0 the new session does not exist yet.

Which tracker: the project option `tracker` (`.claude/scripts/cg-option.sh tracker`):
  none     — every call answers "skipped"; the workflow runs as without a tracker
  adapter  — .claude/tracker-adapter.py, owned by the project, run with this interpreter

The adapter takes exactly the arguments above (with --id resolved) and prints exactly
one JSON line — the same contract this bridge prints:
  {"ok": true, "key": "ABC-12", "id": "...", "url": "...", ...}
      `get` adds "description" (plain text) and "state" (the tracker's state name)
  {"ok": false, "skipped": true, "reason": "..."}   not configured / nothing to do
  {"ok": false, "error": "..."}                     the tracker refused or is unreachable
Exit codes: 0 ok or skipped; 1 error; 2 bad usage or broken config. Credentials and
any per-developer settings are the adapter's business and never belong in the repo.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ADAPTER = Path(".claude/tracker-adapter.py")
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


def adapter_argv(args: argparse.Namespace, argv: list[str]) -> list[str]:
    if args.cmd not in ("event", "move", "status") or args.id:
        return argv
    item_id = session_item_id()
    if not item_id:
        emit({"ok": False, "error": "no tracker item for this session (pass --id)"}, 1)
    return [*argv, "--id", item_id]


def run_adapter(argv: list[str]) -> None:
    result = subprocess.run(
        [sys.executable, str(ADAPTER), *argv], capture_output=True, text=True,
        encoding="utf-8", env={**os.environ, "PYTHONIOENCODING": "utf-8"},
    )
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    try:
        reply = json.loads(lines[-1]) if lines else None
    except ValueError:
        reply = None
    if not isinstance(reply, dict):
        # The contract is broken (crash, stray output); say why instead of passing on silence.
        detail = (result.stderr.strip() or result.stdout.strip())[-600:]
        emit({"ok": False, "error": f"{ADAPTER} broke the contract (exit {result.returncode}): {detail}"}, 1)
    emit(reply, result.returncode if result.returncode in (0, 1, 2) else 1)


def main(argv: list[str]) -> None:
    # Tracker state names are often non-ASCII; the console code page on Windows would mangle them.
    sys.stdout.reconfigure(encoding="utf-8")
    args = parse(argv)
    kind = tracker_kind()
    if kind == "none":
        skipped("no tracker configured (option tracker=none)")
    if kind != "adapter":
        emit({"ok": False, "error": f"unknown tracker option: {kind} (expected none or adapter)"}, 2)
    if not ADAPTER.exists():
        skipped(f"tracker=adapter but {ADAPTER} is missing")
    run_adapter(adapter_argv(args, argv))


if __name__ == "__main__":
    main(sys.argv[1:])
