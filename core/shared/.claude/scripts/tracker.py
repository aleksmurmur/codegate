#!/usr/bin/env python3
"""Issue-tracker bridge for the codegate workflow.

Codegate knows no tracker. It asks for abstract actions; the project's adapter decides what
they mean in its tracker. Events:
  started     — a task began (Phase 0): an item is created, or an existing one taken up
  pr_created  — its PR/MR exists (Phase 5)
  merged      — its PR/MR is merged (/cg-merged)

Usage:
  tracker.py create --title T [--description D | --body-file F] [--type feature|bugfix|refactor]
                    [--project ALIAS] [--relates KEY:TYPE]... [--link URL]
  tracker.py get    <KEY>           an existing item: title, plain-text description, state
  tracker.py event  <started|pr_created|merged> [--id ID]
  tracker.py move   <tracker state name> [--id ID]
  tracker.py status [--id ID]
  tracker.py comment (--body B | --body-file F) [--id ID]
  tracker.py link   --relates KEY:TYPE [--id ID]
  tracker.py list   [--mine] [--project ALIAS]
  tracker.py check                  verify the adapter's config and credentials
  tracker.py capabilities           what the adapter can do

Bodies (--body-file, --body) are markdown; turning them into the tracker's format is the
adapter's job. TYPE of a relation is one of: relates, blocks, blocked_by, caused_by — how
each maps onto the tracker is the adapter's business too. ALIAS is a name the project gave
another project (option `consumers`, e.g. web); the adapter knows which tracker
project it is. Without --project an action is about this repository's own project.

Without --id, `event`/`move`/`status`/`comment`/`link` use the item of the task on the
checked-out branch (`tracker.json` of its session); the adapter always receives an explicit
--id. `create` never writes session files.

Which tracker: the project option `tracker` (`.claude/scripts/cg-option.sh tracker`):
  none     — every call answers "skipped"; the workflow runs as without a tracker
  adapter  — the project's own adapter, in one or both forms:
             .claude/tracker-adapter.py  a script run with this interpreter;
             .claude/tracker.md          how to do an action with the user's own tracker tools
                                         (an MCP server, a CLI) — for the agent to follow.

The script takes exactly the arguments above (with --id resolved) and prints exactly one
JSON line — the same contract this bridge prints:
  {"ok": true, "key": "ABC-12", "id": "...", "url": "...", ...}
      `get` adds "description" (plain text) and "state"; `list` answers {"ok": true,
      "items": [{"key", "id", "name", "state", "url"}, ...]}; `capabilities` answers
      {"ok": true, "actions": [...]}, the names below
  {"ok": false, "skipped": true, "reason": "..."}   not configured / nothing to do
  {"ok": false, "error": "..."}                     the tracker refused or is unreachable
Exit codes: 0 ok or skipped; 1 error; 2 bad usage or broken config. Credentials and any
per-developer settings are the adapter's business and never belong in the repo.

Capabilities are named `create`, `create:project`, `create:relates`, `create:link`,
`create:body_file`, `get`, `event:<name>`, `move`, `status`, `check`, `comment`, `link`,
`list`. A script without `capabilities` is taken to support the original set: create, get,
event:started, event:pr_created, move, status, check. A call the script cannot make is
answered {"ok": false, "delegate": "agent", "how": ".claude/tracker.md", "action": [...]}
when tracker.md exists — the agent does it with the user's tools — and "skipped" otherwise.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cg_session  # noqa: E402

ADAPTER = Path(".claude/tracker-adapter.py")
INSTRUCTIONS = Path(".claude/tracker.md")
EVENTS = ("started", "pr_created", "merged")
RELATIONS = ("relates", "blocks", "blocked_by", "caused_by")
ORIGINAL = {"create", "get", "event:started", "event:pr_created", "move", "status", "check"}
NEEDS_ITEM = ("event", "move", "status", "comment", "link")


def emit(obj: dict, code: int = 0) -> None:
    print(json.dumps(obj, ensure_ascii=False))
    sys.exit(code)


def skipped(reason: str) -> None:
    emit({"ok": False, "skipped": True, "reason": reason})


def tracker_kind() -> str:
    # Read here rather than through cg-option.sh: `bash` from Python on Windows may resolve to WSL.
    return cg_session.option("tracker", "none")


def session_item_id() -> str | None:
    sid = cg_session.current()
    if not sid:
        return None
    item = cg_session.reconcile(sid) / "tracker.json"
    try:
        return json.loads(item.read_text(encoding="utf-8")).get("id")
    except (ValueError, OSError):
        return None


def relation(value: str) -> str:
    key, _, kind = value.rpartition(":")
    if not key or kind not in RELATIONS:
        raise argparse.ArgumentTypeError(f"expected KEY:TYPE, TYPE one of {', '.join(RELATIONS)}")
    return value


def parse(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="codegate issue-tracker bridge")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create")
    c.add_argument("--title", required=True)
    body = c.add_mutually_exclusive_group()
    body.add_argument("--description")
    body.add_argument("--body-file")
    c.add_argument("--type", choices=["feature", "bugfix", "refactor"])
    c.add_argument("--project")
    c.add_argument("--relates", action="append", type=relation, default=[])
    c.add_argument("--link")
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
    k = sub.add_parser("comment")
    kb = k.add_mutually_exclusive_group(required=True)
    kb.add_argument("--body")
    kb.add_argument("--body-file")
    k.add_argument("--id")
    ln = sub.add_parser("link")
    ln.add_argument("--relates", action="append", type=relation, required=True)
    ln.add_argument("--id")
    ls = sub.add_parser("list")
    ls.add_argument("--mine", action="store_true")
    ls.add_argument("--project")
    sub.add_parser("check")
    sub.add_parser("capabilities")
    return p.parse_args(argv)


def needed(args: argparse.Namespace) -> set[str]:
    if args.cmd == "create":
        need = {"create"}
        for opt, cap in (("project", "create:project"), ("relates", "create:relates"), ("link", "create:link")):
            if getattr(args, opt):
                need.add(cap)
        return need
    if args.cmd == "event":
        return {f"event:{args.name}"}
    return {args.cmd}


def run_adapter(argv: list[str]) -> tuple[dict | None, int, str]:
    result = subprocess.run(
        [sys.executable, str(ADAPTER), *argv], capture_output=True, text=True,
        encoding="utf-8", env={**os.environ, "PYTHONIOENCODING": "utf-8"},
    )
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    try:
        reply = json.loads(lines[-1]) if lines else None
    except ValueError:
        reply = None
    detail = (result.stderr.strip() or result.stdout.strip())[-600:]
    return (reply if isinstance(reply, dict) else None), result.returncode, detail


def capabilities() -> set[str]:
    reply, _, _ = run_adapter(["capabilities"])
    if reply and reply.get("ok") and isinstance(reply.get("actions"), list):
        return set(reply["actions"])
    return set(ORIGINAL)


def degrade(args: argparse.Namespace, argv: list[str], caps: set[str]) -> list[str]:
    """Rewrite what an older script cannot take but can still be told another way."""
    if args.cmd == "create" and args.body_file and "create:body_file" not in caps:
        text = Path(args.body_file).read_text(encoding="utf-8")
        i = argv.index("--body-file")
        return [*argv[:i], "--description", text, *argv[i + 2:]]
    return argv


def with_item(args: argparse.Namespace, argv: list[str]) -> list[str]:
    if args.cmd not in NEEDS_ITEM or args.id:
        return argv
    item_id = session_item_id()
    if not item_id:
        emit({"ok": False, "error": "no tracker item for the task on this branch (pass --id)"}, 1)
    return [*argv, "--id", item_id]


def delegate(argv: list[str], why: str) -> None:
    if INSTRUCTIONS.exists():
        emit({"ok": False, "delegate": "agent", "how": str(INSTRUCTIONS).replace(os.sep, "/"),
              "action": argv, "reason": why})
    skipped(why)


def main(argv: list[str]) -> None:
    # Tracker state names are often non-ASCII; the console code page on Windows would mangle them.
    sys.stdout.reconfigure(encoding="utf-8")
    args = parse(argv)
    kind = tracker_kind()
    if kind == "none":
        skipped("no tracker configured (option tracker=none)")
    if kind != "adapter":
        emit({"ok": False, "error": f"unknown tracker option: {kind} (expected none or adapter)"}, 2)
    if args.cmd == "capabilities" and not ADAPTER.exists():
        emit({"ok": True, "actions": [], "delegate": INSTRUCTIONS.exists()})
    if not ADAPTER.exists():
        delegate(argv, f"tracker=adapter but {ADAPTER} is missing")

    caps = capabilities()
    if args.cmd == "capabilities":
        emit({"ok": True, "actions": sorted(caps), "delegate": INSTRUCTIONS.exists()})
    argv = with_item(args, argv)
    missing = needed(args) - caps
    if missing:
        delegate(argv, f"the adapter does not support {', '.join(sorted(missing))}")
    argv = degrade(args, argv, caps)

    reply, code, detail = run_adapter(argv)
    if reply is None:
        # The contract is broken (crash, stray output); say why instead of passing on silence.
        emit({"ok": False, "error": f"{ADAPTER} broke the contract (exit {code}): {detail}"}, 1)
    emit(reply, code if code in (0, 1, 2) else 1)


if __name__ == "__main__":
    main(sys.argv[1:])
