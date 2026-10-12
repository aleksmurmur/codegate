Show the status of this checkout's task.

Steps:
1. `python3 .claude/scripts/cg_session.py dir` → this checkout's session (`.ai/sessions/{id}`).
2. Empty: say "No task on branch `<branch>`. Start one with /cg-feature, /cg-bugfix or
   /cg-refactor; `/cg-tasks` lists the tasks in other branches and worktrees."
3. Otherwise read `task.md`, `state`, `mode`, `ticket`, `pr-url`, the last 3 lines of `audit.log`.
4. Report: session id, ticket, task (first line), state and mode, recent activity, next step.

Next step by state:
- IDLE → elicitation is open: answer its questions
- ELICITED → planning
- PLAN_APPROVED / IMPLEMENTING → implementation in progress
- QUALITY_REVIEWED → gate report in QUALITY_REPORT.md; fixes or the PR/MR next
- PR_CREATED / PR_UPDATED → MR open (url); fixes to it are rework; `/cg-mr` checks for a merge
- REWORK → a fix to the open MR is in progress; the delta check comes before the push
- MERGED / ABANDONED → closed; new work starts a new task

Interactive sessions: name the `/cg-approve` the state is waiting for.
