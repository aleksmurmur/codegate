---
description: Is this task's PR/MR merged? Closes the task when it is; otherwise shows what is open
---

The current task's PR/MR, from git facts. Follow the section "Merged — `/cg-mr`" of the
skill `cg-rework`:

1. `git fetch origin`, then `python3 .claude/scripts/cg_session.py facts`.
2. `merged: true` → state `MERGED`, audit `[ts] Merged into <target>`,
   `python3 .claude/scripts/tracker.py event merged` (report skip/error in one line). Say the
   task is closed and the next one starts from a fresh base branch.
3. Not merged → the MR url (`pr-url` in the session), state, commits since `checked-sha` that
   are not yet checked or pushed, and the next step.
4. No task on this branch → say so; `/cg-tasks` lists the others.

Squash merges do not show as merged (the commits differ): if the user says it is merged,
believe them and close it the same way.

Respond in the user's language.
