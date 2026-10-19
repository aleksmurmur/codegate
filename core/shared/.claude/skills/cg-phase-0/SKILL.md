---
name: cg-phase-0
description: Codegate Phase 0 — start a new task. Use whenever work begins that is not the task on the current branch (a /cg-feature, /cg-bugfix, /cg-refactor, or a message that turns out to be a different task). Decides what happens to the task already in this folder, picks this folder or a new worktree, creates the branch and the tracker item.
user-invocable: false
---

# Phase 0 — Start a task

Every task gets its own branch, and its own session bound to that branch, before anything
else is written. The session is found by the branch checked out (`cg_session.py`), so a
task in another folder or on another branch is never disturbed by this one.

Options (`.claude/scripts/cg-option.sh <key>`): `base_branch` — where task branches start and
merge back; `branch_pattern` — how they are named.

## 1. What is in this folder now

```bash
git fetch origin
BASE=$(.claude/scripts/cg-option.sh base_branch main)
PATTERN=$(.claude/scripts/cg-option.sh branch_pattern '{type}/{ticket}-{slug}')
CURRENT=$(git branch --show-current)
python3 .claude/scripts/cg_session.py facts
```

`facts` describes the checkout from git, not from what a session file claims: `status` is
one of `base`, `in-progress` (uncommitted changes), `merged`, `review-open`, `paused`, `stale`
(idle for days), `no-session`. Decide what happens to the task already here, and where the
new one goes:

| `status` here | The task already here | The new task goes |
|---|---|---|
| `base` | — | this folder, new branch from fresh `BASE` |
| `in-progress` | paused, untouched | **new worktree** |
| a live chat works here (the `codegate:` line says so, or the harness can list sessions and one is busy in this repo) | untouched | **new worktree** |
| `merged` | write `MERGED` to its state, `tracker.py event merged` | this folder, new branch from fresh `BASE` |
| `review-open` | stays as is (its PR/MR is open) | this folder, new branch from fresh `BASE` |
| `stale` | ask one line: "close `<branch>` as no longer relevant?" — yes → write `ABANDONED` to its state; no → paused | this folder, new branch from fresh `BASE` |
| `no-session`, and the branch carries the key of the task being started (an earlier chat made the branch and the item, but no session) | — | **this branch**, no new one; the item is `tracker.py get <KEY>` (§2), no new item. The task was given as text: ask once whether it is that item. Target: `BASE`, unless the branch was cut from another unmerged branch — then ask |
| `paused`, `no-session` | paused | this folder, new branch from fresh `BASE` |

A stacked task (the new work needs the current branch's unmerged code) is the one exception:
only when the user says so, or the task text plainly builds on the current branch, branch
from `CURRENT` instead of `BASE`; its **target** is then `CURRENT`. If unsure, ask:
"Build on top of `<CURRENT>` or start from `<BASE>`?"

Another chat in this folder: when the harness lets you message other sessions, you may ask
it only when its answer changes the decision and it is idle. By default go to a new worktree without asking.

## 2. Ticket

- **The task is a tracker key** (`/cg-feature ABC-123 …`): `python3 .claude/scripts/tracker.py get <KEY>`.
  - `{"ok": true}` → the task is its `name` and `description` plus the user's notes; the
    ticket is the key. Show the title and first lines of the description; keep `id`, `key`,
    `url`; after the branch exists run `tracker.py event started --id <id>`.
  - `{"ok": false}` → show the error, ask for the task text or another key.
    `{"skipped": true}` → no tracker: the key is just the ticket; ask what the task is.
- **Otherwise** create the item: `python3 .claude/scripts/tracker.py create --type {type} --title "<short title>" --description "<task text>"`.
  A defect in a task that is already merged, or an extension of an existing task, is linked
  to it: add `--relates <ORIGINAL-KEY>:caused_by` (defect) or `--relates <ORIGINAL-KEY>:relates`
  (extension).
  - `{"ok": true, "key": …}` → the ticket; keep `id`, `key`, `url`.
  - `{"skipped": true}` → no tracker: take a key from the task text (`[A-Z][A-Z0-9]+-\d+`); if
    `PATTERN` has `{ticket}` and there is none, ask.
  - `{"delegate": "agent", "how": …}` → do the action yourself with the user's tracker tools
    as that file describes, then go on with the key you got.
  - `{"ok": false}` → show the error; ask: retry, a key by hand, or no key.
  Never invent a key. No key → drop `{ticket}` and its separator from the name.

## 3. Branch (and worktree)

- **Slug**: lowercase ASCII from the task, `[a-z0-9-]`, ~40 chars; non-ASCII task → ask for a
  short English slug. Fill `PATTERN`; say the name in one line, do not ask for it.
- **This folder**: `git fetch origin && git switch --no-track -c <name> origin/$BASE`. It
  starts from the latest remote state and works in a worktree too, where `$BASE` is usually
  checked out by another checkout. No `reset --hard`, no merge. A stacked task:
  `git switch --no-track -c <name>` — from `CURRENT` as it is here, unpushed commits included.
- **New worktree**:
  `MAIN=$(git worktree list --porcelain | sed -n '1s/^worktree //p')` (the main checkout — not
  the current one, which may itself be a worktree), then
  `git worktree add --no-track -b <name> "$MAIN/.claude/worktrees/<slug>" <from>`, where `<from>` is
  `origin/$BASE` (or `CURRENT` for a stacked task), and move
  the conversation into it with `EnterWorktree` (`path` = that directory). Everything after this
  — session files, hooks, commits — happens there. Without that tool (or when it fails) the
  conversation and its sub-agents stay in this folder: stop, and tell the user to open a new
  conversation in that directory and run `/cg-resume` there, or to take **This folder**.
- Never `git checkout -b <name> origin/$BASE` (without `--no-track`): `origin/$BASE` would become
  the upstream and a bare `git push` would target the shared branch.
- The task's **target** (where its PR/MR goes) is `BASE` (or `CURRENT` for a stacked task).

Switching to a new task in the same chat carries the old task's conversation along. Say in
one line that `/clear` then `/cg-resume` starts this task with a clean context — cheaper and
less confusing; the session files hold everything needed.

## 4. Session

Then Phase 1 starts the session (skill `cg-phase-1`): it records the branch, target, ticket
and tracker item.
