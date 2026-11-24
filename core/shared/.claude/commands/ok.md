"Yes, go on" to what the current task is waiting for. Optional argument: `$ARGUMENTS`.

With an argument, run `/cg-approve <argument>` (`.claude/commands/cg-approve.md`) and stop
here. Phases proceed by themselves, so without one `/ok` answers the one stop the task is at.

1. `python3 .claude/scripts/cg_session.py dir` → this checkout's session. Empty: say "No active
   session. Start with `/cg-feature`, `/cg-bugfix`, or `/cg-refactor`." Stop.
2. Read `{dir}/state` (missing or unreadable: say so, point to `/cg-status`, stop), whether
   `{dir}/elicitation.md` has `## Elicitation complete`, the verdict line of
   `{dir}/QUALITY_REPORT.md`, and the last 5 lines of `{dir}/audit.log`.
3. The first row that matches decides:

   | State | Signal | Action |
   |---|---|---|
   | IDLE | `elicitation.md` exists without `## Elicitation complete` — a round is open | answer it "all as recommended", but FIRST print "Accepting this round's recommendations via /ok."; then continue Phase 1 (skill `cg-phase-1`) |
   | QUALITY_REVIEWED | verdict `FAIL`, no `Quality gate override` in the audit | **refuse**: "Quality gate is FAIL. /ok will not override it — type `/cg-approve quality` to override (findings marked `[no override]` cannot be overridden at all)." Stop. |
   | QUALITY_REVIEWED | the audit has `Independent review started` and the review waits on the user | proceed: finish Phase 4 §5 (skill `cg-phase-4`) |
   | PR_CREATED / PR_UPDATED | — | "The PR/MR exists — nothing to approve. Fixes to it are rework; `/cg-merged` checks for a merge." Stop. |
   | REWORK | — | "Rework in progress — the delta check runs before the push (skill `cg-rework`). Nothing to approve." Stop. |
   | MERGED / ABANDONED | — | "The task is closed. New work starts a new task." Stop. |
   | anything else | — | nothing waits on the user: continue the current phase, as `/cg-resume` does |

4. Before acting, say in one line what `/ok` is doing: `State: {STATE}. /ok — <action>.`
