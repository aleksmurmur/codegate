#!/usr/bin/env python3
"""Which codegate session belongs to this checkout, and where sessions live.

A session belongs to a branch: `.ai/sessions/<id>/branch` names it (older sessions name it
in their audit log, `Branch <name> from <target>`). The current session is the one whose
branch is checked out here, so moving to another worktree or branch moves to another task;
there is no repository-wide pointer to go stale. Only sessions that name no branch at all
fall back to the old pointer `.ai/current-session`.

The agent writes a session inside its own checkout (`.ai/sessions/<id>/`). A copy lives in
the repository's common git dir (`<git-common-dir>/codegate/sessions/<id>/`): shared by every
worktree, kept when a worktree is removed. The two are merged file by file, newer wins.

Usage:
  cg_session.py current          the session id for this checkout; exit 1 if there is none
  cg_session.py dir              its directory, restored from the shared copy when missing
  cg_session.py state            its state; empty when there is no session
  cg_session.py sync             copy every session of this checkout into the shared store
  cg_session.py list [--json]    every known session: branch, state, worktree, last activity
  cg_session.py facts            JSON facts about this checkout for the task-boundary decision
  cg_session.py claim --chat ID  record that chat ID is working in this checkout; prints the
                                 previous chat when another one was active here recently
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

# A chat that touched this checkout within this window is treated as still working in it.
LIVE_MINUTES = int(os.environ.get("CG_LIVE_MINUTES", "30"))
# A paused task idle this long is offered for closing as no longer relevant.
STALE_DAYS = int(os.environ.get("CG_STALE_DAYS", "7"))

AFTER_PR = ("PR_CREATED", "REWORK", "PR_UPDATED", "MERGED")
BRANCH_IN_AUDIT = re.compile(r"\] Branch (\S+) from ")


def git(*args: str) -> str | None:
    try:
        r = subprocess.run(["git", *args], capture_output=True, text=True, encoding="utf-8")
    except OSError:
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def read(path: Path | None) -> str:
    if path is None:
        return ""
    try:
        return path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError):
        return ""


def toplevel() -> Path:
    top = git("rev-parse", "--show-toplevel")
    return Path(top) if top else Path.cwd()


def local_root() -> Path:
    return toplevel() / ".ai" / "sessions"


def common_dir() -> Path | None:
    common = git("rev-parse", "--path-format=absolute", "--git-common-dir")
    if not common:
        rel = git("rev-parse", "--git-common-dir")
        if not rel:
            return None
        common = str((Path.cwd() / rel).resolve())
    return Path(common) / "codegate"


def store_root() -> Path | None:
    common = common_dir()
    return common / "sessions" if common else None


def option(key: str, default: str = "") -> str:
    manifest = Path(os.environ.get("CG_MANIFEST", toplevel() / ".claude" / "codegate-installed.yml"))
    in_options = False
    for line in read(manifest).splitlines():
        if line.rstrip() == "options:":
            in_options = True
        elif in_options and line[:1] not in (" ", ""):
            break
        elif in_options and line.strip().startswith(key + ":"):
            return line.split(":", 1)[1].strip() or default
    return default


def session_dirs() -> dict[str, list[Path]]:
    """id -> its copies, local first."""
    found: dict[str, list[Path]] = {}
    for root in (local_root(), store_root()):
        if root and root.is_dir():
            for d in sorted(root.iterdir()):
                if d.is_dir():
                    found.setdefault(d.name, []).append(d)
    return found


def newest(copies: list[Path], name: str) -> Path:
    present = [c for c in copies if (c / name).exists()]
    if not present:
        return copies[0] / name
    return max(present, key=lambda c: (c / name).stat().st_mtime) / name


def session_branch(copies: list[Path]) -> str:
    branch = read(newest(copies, "branch"))
    if branch:
        return branch
    m = BRANCH_IN_AUDIT.search(read(newest(copies, "audit.log")))
    return m.group(1) if m else ""


def current_branch() -> str:
    """The checked-out branch; during a rebase (detached HEAD) the branch being rebased."""
    branch = git("branch", "--show-current")
    if branch:
        return branch
    for state_dir in ("rebase-merge", "rebase-apply"):
        head = git("rev-parse", "--git-path", f"{state_dir}/head-name")
        name = read(Path(head)) if head else ""
        if name.startswith("refs/heads/"):
            return name[len("refs/heads/"):]
    return ""


def current() -> str | None:
    branch = current_branch()
    dirs = session_dirs()
    if branch:
        mine = [sid for sid, copies in dirs.items() if session_branch(copies) == branch]
        if mine:
            return max(mine)  # ids start with a timestamp: the latest task on this branch
    pointer = read(local_root().parent / "current-session")
    if pointer and pointer in dirs and not session_branch(dirs[pointer]):
        return pointer
    return None


def merge(src: Path, dst: Path) -> None:
    for f in src.rglob("*"):
        if not f.is_file():
            continue
        target = dst / f.relative_to(src)
        if not target.exists() or f.stat().st_mtime > target.stat().st_mtime + 0.001:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, target)


def reconcile(sid: str) -> Path:
    local = local_root() / sid
    store = store_root()
    if store:
        shared = store / sid
        if local.is_dir():
            merge(local, shared)
        if shared.is_dir():
            merge(shared, local)
    return local


def sync() -> None:
    store = store_root()
    root = local_root()
    if not store or not root.is_dir():
        return
    for d in root.iterdir():
        if d.is_dir():
            merge(d, store / d.name)


def worktrees() -> dict[str, str]:
    """branch -> worktree path"""
    out: dict[str, str] = {}
    path = None
    for line in (git("worktree", "list", "--porcelain") or "").splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line.startswith("branch refs/heads/") and path:
            out[line[len("branch refs/heads/"):]] = path
    return out


def mtime(path: Path) -> float | None:
    try:
        return path.stat().st_mtime
    except OSError:
        return None


def listing() -> list[dict]:
    wt = worktrees()
    rows = []
    for sid, copies in sorted(session_dirs().items()):
        branch = session_branch(copies)
        seen = mtime(newest(copies, "audit.log"))
        rows.append({
            "id": sid,
            "branch": branch,
            "state": read(newest(copies, "state")),
            "ticket": read(newest(copies, "ticket")),
            "worktree": wt.get(branch, ""),
            "last_activity": time.strftime("%Y-%m-%d %H:%M", time.localtime(seen)) if seen else "",
        })
    return rows


def claims_file() -> Path | None:
    common = common_dir()
    if not common:
        return None
    key = hashlib.sha1(str(toplevel()).lower().encode("utf-8")).hexdigest()[:16]
    return common / "claims" / f"{key}.json"


def read_claim() -> dict:
    try:
        return json.loads(read(claims_file()) or "{}")
    except ValueError:
        return {}


def claim(chat: str) -> dict:
    prior = read_claim()
    path = claims_file()
    if path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"chat": chat, "worktree": str(toplevel()), "at": time.time()}),
                        encoding="utf-8")
    age = (time.time() - prior.get("at", 0)) / 60
    if prior.get("chat") and prior["chat"] != chat and age < LIVE_MINUTES:
        return {"other_chat": prior["chat"], "minutes_ago": int(age)}
    return {}


def target_ref(target: str) -> str | None:
    for ref in (f"origin/{target}", target):
        if git("rev-parse", "--verify", "--quiet", ref + "^{commit}"):
            return ref
    return None


def facts() -> dict:
    branch = current_branch()
    base = option("base_branch", "main")
    sid = current()
    copies = session_dirs().get(sid, []) if sid else []
    state = read(newest(copies, "state")) if copies else ""
    target = (read(newest(copies, "target-branch")) if copies else "") or base
    changed = [line[3:] for line in (git("status", "--porcelain", "--untracked-files=no") or "").splitlines()
               if line[3:] and not line[3:].startswith(".ai/")]
    # Untracked files count when they are newer than the last commit and than the task itself:
    # a new file the implementer has not committed yet is work in progress; old scratch is not.
    since = float(git("log", "-1", "--format=%ct") or 0)
    if copies and mtime(newest(copies, "task.md")):
        since = max(since, mtime(newest(copies, "task.md")))
    top = toplevel()
    for name in (git("ls-files", "--others", "--exclude-standard") or "").splitlines():
        if name.startswith((".ai/", ".claude/worktrees/")):
            continue
        seen = mtime(top / name)
        if seen and seen > since:
            changed.append(name)
    ref = target_ref(target)
    ahead = int(git("rev-list", "--count", f"{ref}..HEAD") or 0) if ref else None
    contained = bool(ref) and git("merge-base", "--is-ancestor", "HEAD", ref) is not None
    committed = bool(copies) and "commit: " in read(newest(copies, "audit.log"))
    # A branch with no commits of its own is also "contained" — only a task that did commit is merged.
    merged = contained and ahead == 0 and (state in AFTER_PR or committed)

    times = []
    if copies and mtime(newest(copies, "audit.log")):
        times.append(mtime(newest(copies, "audit.log")))
    if ahead:
        last_commit = git("log", "-1", "--format=%ct")
        if last_commit:
            times.append(float(last_commit))
    idle_days = round((time.time() - max(times)) / 86400, 1) if times else None

    if changed:
        status = "in-progress"
    elif branch in (base, "main", "master") or not branch:
        status = "base"
    elif not sid:
        status = "no-session"
    elif state == "MERGED" or merged:
        status = "merged"
    elif state in AFTER_PR:
        status = "mr-open"
    elif idle_days is not None and idle_days >= STALE_DAYS:
        status = "stale"
    else:
        status = "paused"

    return {
        "branch": branch,
        "base": base,
        "session": sid,
        "state": state,
        "target": target,
        "uncommitted": len(changed),
        "ahead_of_target": ahead,
        "merged": merged,
        "idle_days": idle_days,
        "status": status,
        "folder": "new-worktree" if changed else "this-folder",
    }


def main(argv: list[str]) -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    cmd = argv[0] if argv else ""
    if cmd == "current":
        sid = current()
        if sid:
            print(sid)
        return 0 if sid else 1
    if cmd == "dir":
        sid = current()
        if not sid:
            return 1
        reconcile(sid)
        print(f".ai/sessions/{sid}")
        return 0
    if cmd == "state":
        sid = current()
        if sid:
            print(read(reconcile(sid) / "state"))
        return 0
    if cmd == "sync":
        sync()
        return 0
    if cmd == "list":
        rows = listing()
        if "--json" in argv:
            print(json.dumps(rows, ensure_ascii=False))
        else:
            for r in rows:
                print("  ".join(r[k] or "-" for k in ("id", "branch", "state", "worktree", "last_activity")))
        return 0
    if cmd == "facts":
        print(json.dumps(facts(), ensure_ascii=False))
        return 0
    if cmd == "claim":
        i = argv.index("--chat") + 1 if "--chat" in argv else len(argv)
        print(json.dumps(claim(argv[i])) if i < len(argv) else "{}")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
