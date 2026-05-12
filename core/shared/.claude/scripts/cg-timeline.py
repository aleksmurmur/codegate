#!/usr/bin/env python3
"""Cross-session timeline for codegate.

Globs `.ai/sessions/*/audit.log` and prints a chronological view of every
session — id, task title, current state, last event. Answers "what has
codegate been doing this week?" without manually opening session folders.

Session id format is `YYYYMMDD-HHMMSS-slug`, so the start date comes from
the directory name itself — no need to parse audit.log timestamps for
ordering.

Usage:
    cg-timeline.py [--since DURATION] [--full]

    --since   only sessions started within this window. Format: `Nd` (days),
              `Nh` (hours), `Nm` (minutes). Examples: 7d, 24h, 30m.
              Omitted: all sessions.
    --full    print every event from each session's audit.log (default is
              just the last event).

Exit codes:
    0 — printed something (or "No sessions found.")
    2 — argument error
"""

from __future__ import annotations

import argparse
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

SESSION_ID = re.compile(r"^(\d{8})-(\d{6})-(.+)$")
DURATION = re.compile(r"^(\d+)([dhm])$")


def parse_duration(s: str) -> timedelta:
    m = DURATION.match(s)
    if not m:
        print(f"error: --since expects Nd|Nh|Nm, got '{s}'", file=sys.stderr)
        sys.exit(2)
    n, unit = int(m.group(1)), m.group(2)
    return {"d": timedelta(days=n), "h": timedelta(hours=n), "m": timedelta(minutes=n)}[unit]


def parse_session_id(name: str) -> tuple[datetime, str] | None:
    m = SESSION_ID.match(name)
    if not m:
        return None
    try:
        dt = datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S")
    except ValueError:
        return None
    return dt, m.group(3)


def task_title(session_dir: Path) -> str:
    task_file = session_dir / "task.md"
    if not task_file.exists():
        return "(no task.md)"
    for line in task_file.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip().lstrip("#").strip()
        if line:
            return line[:80]
    return "(empty task.md)"


def session_state(session_dir: Path) -> str:
    state_file = session_dir / "state"
    if not state_file.exists():
        return "?"
    return state_file.read_text(encoding="utf-8", errors="replace").strip() or "?"


def audit_lines(session_dir: Path) -> list[str]:
    log = session_dir / "audit.log"
    if not log.exists():
        return []
    return [
        ln.rstrip()
        for ln in log.read_text(encoding="utf-8", errors="replace").splitlines()
        if ln.strip()
    ]


def render(sessions: list[tuple[datetime, str, Path]], full: bool) -> None:
    print(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    print(f"Sessions:  {len(sessions)}")
    print()
    if not sessions:
        print("No sessions found.")
        return
    for started, slug, sdir in sessions:
        state = session_state(sdir)
        title = task_title(sdir)
        date = started.strftime("%Y-%m-%d %H:%M")
        print(f"[{date}] {slug:<40s} {state}")
        print(f"  Task: {title}")
        events = audit_lines(sdir)
        if not events:
            print("  (audit.log empty)")
        elif full:
            for line in events:
                print(f"  {line}")
        else:
            print(f"  Last: {events[-1]}")
        print()


def main() -> None:
    parser = argparse.ArgumentParser(description="codegate cross-session timeline")
    parser.add_argument(
        "--since",
        help="filter to sessions started within this window (Nd, Nh, Nm)",
        default=None,
    )
    parser.add_argument(
        "--full",
        action="store_true",
        help="print every event from each session's audit.log",
    )
    parser.add_argument(
        "--root",
        default=".ai/sessions",
        help="path to sessions directory (default: .ai/sessions)",
    )
    args = parser.parse_args()

    root = Path(args.root)
    if not root.is_dir():
        print(f"No sessions directory at {root} — nothing to show.")
        sys.exit(0)

    cutoff = datetime.now() - parse_duration(args.since) if args.since else None

    sessions: list[tuple[datetime, str, Path]] = []
    for entry in root.iterdir():
        if not entry.is_dir():
            continue
        parsed = parse_session_id(entry.name)
        if parsed is None:
            continue
        started, slug = parsed
        if cutoff is not None and started < cutoff:
            continue
        sessions.append((started, slug, entry))

    sessions.sort(key=lambda t: t[0])
    render(sessions, args.full)


if __name__ == "__main__":
    main()
