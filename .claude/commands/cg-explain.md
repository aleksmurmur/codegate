Read-only inspector — print state, what's been done, and the diff so far.

This is `/cg-status` plus the actual diff and checklist progress. No side
effects. No state advance. Useful when context is murky after `/clear` or
when reviewing someone else's in-flight session.

Steps:

1. Read `.ai/current-session`. If missing or empty: say "No active session."
   and stop.

2. Otherwise read:
   - `.ai/sessions/{id}/task.md` — task description
   - `.ai/sessions/{id}/state` — current phase
   - `.ai/sessions/{id}/PLAN.md` — checklist (if it exists; absent before Phase 2)
   - `.ai/sessions/{id}/audit.log` — last 5 lines for recent activity
   - `.ai/sessions/{id}/decisions/` — list filenames if any
   - `.ai/sessions/{id}/clarifications.md` — list unresolved questions if any

3. Determine the baseline commit. The session's first audit-log entry usually
   records `Plan approved, implementation started` — the commit at HEAD just
   before that is the baseline. If the session hasn't reached IMPLEMENTING
   yet, there is no diff to show; skip step 4.

   Practical: run `git log --oneline` and find the commit recorded near the
   `Plan approved` entry, or use `git merge-base main HEAD` as a fallback.

4. Run `git diff <baseline>..HEAD --stat` to get the file change summary.
   For each Modify/Create file in the checklist, indicate whether it appears
   in the diff stat (touched) or not (pending).

5. Print a unified report in this shape:

   ```
   Session: 20260508-143022-add-weekly-digest
   Task: Add weekly email digest for uptime summary
   State: IMPLEMENTING

   Recent activity (audit.log tail):
     [10:14] Plan approved, implementation started
     [10:31] commit: 7a3b9c1 — test: add DigestScheduler tests
     [10:38] commit: f2c4e5d — feat: implement weekly digest job

   Checklist progress:
     [x] 1. Modify src/main/.../DigestScheduler.kt
     [x] 2. Create src/main/.../DigestJob.kt
     [ ] 3. Modify src/main/.../UserPreferences.kt
     [ ] 4. Create src/test/.../DigestJobTest.kt

   Diff (since 7a3b9c1):
     src/main/kotlin/.../DigestScheduler.kt    | 18 ++++++++++++++++++
     src/main/kotlin/.../DigestJob.kt          | 42 +++++++++++++++++++++++
     2 files changed, 60 insertions(+)

   Decisions logged: 2 (001-flyway-version-bump.md, 002-cron-vs-scheduler.md)
   Open clarifications: 0

   Next action: Continue implementation from checklist item 3.
   ```

6. Do not modify any session files. Do not advance state. Do not commit.
   This is purely a read-and-report command.

If `.ai/sessions/{id}/state` is `IDLE` or `ELICITED`, the diff section is
not applicable — say "No diff yet — implementation starts after /cg-approve plan."

If `.ai/sessions/{id}/state` is `QUALITY_REVIEWED` or `PR_CREATED`, also
include the verdict line from `QUALITY_REPORT.md` if it exists.
