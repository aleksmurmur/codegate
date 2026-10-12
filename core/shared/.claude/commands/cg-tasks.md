---
description: List every codegate task in this repository — branch, state, worktree, last activity
---

List the tasks of this repository across all branches and worktrees. Read-only.

1. `python3 .claude/scripts/cg_session.py list --json` — every session, from this checkout and
   from the shared store in the git directory (sessions of removed worktrees included).
2. Leave out `MERGED` and `ABANDONED` ones unless `$ARGUMENTS` contains `all`.
3. Show a table: ticket (or session id), branch, state, worktree (`-` = branch checked out
   nowhere), last activity. Mark the row of this checkout. Sort by last activity, newest first.
4. Below it, one line per task that needs attention, only when it applies: an MR open for
   days, rework not pushed, a task idle for over a week (offer to close it as no longer
   relevant), a branch checked out nowhere with unfinished work.

To continue a task in another worktree: `EnterWorktree` with that path, then `/cg-resume`.
Branch checked out nowhere: `git worktree add <path> <branch>` first.

Respond in the user's language.
