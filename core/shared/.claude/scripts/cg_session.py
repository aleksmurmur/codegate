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
  cg_session.py dir [--branch B] its directory, restored from the shared copy when missing
                                 (--branch: the session of branch B instead of the checked-out one)
  cg_session.py state            its state; empty when there is no session
  cg_session.py sync             copy every session of this checkout into the shared store
  cg_session.py list [--json]    every known session: branch, state, worktree, last activity
  cg_session.py base             the commit this task's diff starts from: the merge-base of HEAD
                                 with its target branch (the remote one unless the local is ahead)
  cg_session.py target-ref [--branch B]
                                 that target branch as a ref (see `base`); exit 1 when there is none
  cg_session.py branch           the branch this checkout's session is bound to; exit 1 when none
  cg_session.py checked          exit 0 when checked-sha covers HEAD: nothing but `.ai/` and
                                 merges of the target branch changed since it
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
from datetime import datetime
from pathlib import Path

# A chat that touched this checkout within this window is treated as still working in it.
LIVE_MINUTES = int(os.environ.get("CG_LIVE_MINUTES", "30"))
# A paused task idle this long is offered for closing as no longer relevant.
STALE_DAYS = int(os.environ.get("CG_STALE_DAYS", "7"))

AFTER_PR = ("PR_CREATED", "REWORK", "PR_UPDATED", "MERGED")
BRANCH_IN_AUDIT = re.compile(r"\] Branch (\S+) from ")
AUDIT_ENTRY = re.compile(r"^\[([^\]]+)\]")


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


def stamp(text: str) -> float | None:
    """An ISO time as `date -Iseconds` and its relatives write it; None when it is not one."""
    s = re.sub(r"Z$", "+00:00", text.strip())
    s = re.sub(r"([+-]\d\d)(\d\d)$", r"\1:\2", s)  # +0300: fromisoformat before 3.11 wants +03:00
    s = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], s)
    try:
        return datetime.fromisoformat(s).timestamp()
    except ValueError:
        return None


def last_entry(audit: Path) -> float:
    """The latest time among the audit log's entries; 0 when none has one.

    File dates are no measure: a checkout of tracked session files dates old content today.
    Entries are not always in order (a backfilled line), so the latest, not the last."""
    times = [stamp(m.group(1)) for m in map(AUDIT_ENTRY.match, read(audit).splitlines()) if m]
    return max((t for t in times if t is not None), default=0.0)


def newest(copies: list[Path], name: str) -> Path:
    present = [c for c in copies if (c / name).exists()]
    if not present:
        return copies[0] / name
    return max(present, key=lambda c: (last_entry(c / "audit.log"), (c / name).stat().st_mtime)) / name


def activity(copies: list[Path]) -> float | None:
    """The last audit entry of any copy; the audit log's file date only when no entry has a time."""
    return max((last_entry(c / "audit.log") for c in copies), default=0.0) or mtime(newest(copies, "audit.log"))


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


def current(branch: str | None = None) -> str | None:
    branch = branch or current_branch()
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
    # The copy whose audit log reaches later wins whatever the file dates say; a copy behind it
    # only fills gaps. File dates decide only between copies equally far along.
    ahead = last_entry(src / "audit.log") - last_entry(dst / "audit.log")
    for f in src.rglob("*"):
        if not f.is_file():
            continue
        target = dst / f.relative_to(src)
        if not target.exists() or ahead > 0 or (
                ahead == 0 and f.stat().st_mtime > target.stat().st_mtime + 0.001):
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
        seen = activity(copies)
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
    """The ref that stands for the target branch: the remote one, unless the local one is ahead."""
    refs = [r for r in (f"origin/{target}", target) if git("rev-parse", "--verify", "--quiet", r + "^{commit}")]
    if not refs:
        return None
    # A local target behind its remote (a worktree never pulls it) would put other people's
    # commits into the diff; one ahead of it (a stacked task's unpushed parent) is the truth.
    if len(refs) == 2 and git("merge-base", "--is-ancestor", refs[0], refs[1]) is not None:
        return refs[1]
    return refs[0]


def session_target(branch: str | None = None) -> str:
    sid = current(branch)
    copies = session_dirs().get(sid, []) if sid else []
    return (read(newest(copies, "target-branch")) if copies else "") or option("base_branch", "main")


def diff_base() -> str | None:
    target = session_target()
    for name in [target] + (["master"] if target == "main" else []):
        ref = target_ref(name)
        if ref:
            return git("merge-base", ref, "HEAD")
    return None


def checked() -> bool:
    sid = current()
    sha = read(newest(session_dirs()[sid], "checked-sha")) if sid else ""
    if not sha or git("merge-base", "--is-ancestor", sha, "HEAD") is None:
        return False
    ref = target_ref(session_target())
    # As the push gate: a merge counts for what resolving it changed (git 2.36+).
    merges = "--remerge-diff" if git("log", "-1", "--remerge-diff", "--format=") is not None else "--no-merges"
    changed = git("log", merges, "--format=", "--name-only", f"{sha}..HEAD", *(["--not", ref] if ref else []))
    return not [f for f in (changed or "").splitlines() if f and not f.startswith(".ai/")]


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
    if copies and activity(copies):
        times.append(activity(copies))
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
        status = "review-open"
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
        sid = current(argv[argv.index("--branch") + 1] if "--branch" in argv[:-1] else None)
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
    if cmd == "base":
        b = diff_base()
        if b:
            print(b)
        return 0 if b else 1
    if cmd == "target-ref":
        ref = target_ref(session_target(argv[argv.index("--branch") + 1] if "--branch" in argv[:-1] else None))
        if ref:
            print(ref)
        return 0 if ref else 1
    if cmd == "branch":
        sid = current(argv[argv.index("--branch") + 1] if "--branch" in argv[:-1] else None)
        b = session_branch(session_dirs()[sid]) if sid else ""
        if b:
            print(b)
        return 0 if b else 1
    if cmd == "checked":
        return 0 if checked() else 1
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
