---
description: Resume an interrupted session — read current state and pick up where you left off
---

# Resume Session

Use this when returning to an interrupted session after context compaction,
a new Claude Code window, or an unexpected stop.

## Steps

1. **Find the active session**

   Read `.ai/current-session` to get the session ID.
   If the file doesn't exist or is empty: say "No active session found. Start a new
   task with /feature, /bugfix, /migration, or /refactor."

2. **Read session state**

   Read these files (skip any that don't exist):
   - `.ai/sessions/{id}/state` — current phase
   - `.ai/sessions/{id}/task.md` — original task description
   - `.ai/sessions/{id}/elicitation.md` — Q&A answers
   - `.ai/sessions/{id}/PLAN.md` — implementation plan with checklist
   - `.ai/sessions/{id}/decisions.md` — decisions made during implementation
   - `.ai/sessions/{id}/audit.log` — last few lines for recent activity

3. **Report where things stand**

   Tell the user clearly:
   - What the task is
   - What phase the session is in (ELICITED / PLAN_APPROVED / IMPLEMENTING / QUALITY_REVIEWED)
   - What has been done (completed checklist items, if in IMPLEMENTING)
   - What comes next (the exact next action)

   Example output:
   ```
   Active session: 20260412-143022-add-weekly-digest
   Task: Add weekly email digest for uptime summary
   State: IMPLEMENTING

   Completed:
   [x] 1. Add digest_sent_at column — V21__add_digest_fields.sql
   [x] 2. Modify DigestScheduler.kt — add weekly job

   Remaining:
   [ ] 3. Add opt-out column to users table — V22__digest_optout.sql
   [ ] 4. Update DigestScheduler to check opt-out before sending
   [ ] 5. Add tests for opt-out logic

   Next step: Continue implementation from item 3.
   I'll pick up from where we left off.
   ```

4. **Resume**

   After reporting, immediately continue from the next step without waiting for the
   user to say "continue" — they ran /resume because they want to keep going.

   Follow CLAUDE.md phase instructions for the current state.
