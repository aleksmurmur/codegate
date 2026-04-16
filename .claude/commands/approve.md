Process an approval for the current session.

Approval type: $ARGUMENTS

Read .ai/current-session to get the current session ID.
Read .ai/sessions/{id}/state to get the current state.

Handle based on approval type:

**elicit** (or "elicit"):
- Verify current state is IDLE
- Write ELICITED to .ai/sessions/{id}/state
- Append to audit log: "[timestamp] Elicitation approved by user"
- Say: "Elicitation approved. Generating plan..."
- Proceed to Phase 2: Planning (generate PLAN.md)

**plan** (or "plan"):
- Verify current state is ELICITED
- Write PLAN_APPROVED to .ai/sessions/{id}/state
- Write IMPLEMENTING to .ai/sessions/{id}/state
- Append to audit log: "[timestamp] Plan approved by user"
- Say: "Plan approved. Beginning implementation..."
- Proceed to Phase 3: Implementation

**implementation** (or "implementation"):
- Verify current state is IMPLEMENTING
- Append to audit log: "[timestamp] Implementation approved by user — committing and running quality gate"
- Commit all uncommitted changes: run `git add -A`, then commit with message matching the task type and description from task.md (e.g. `feat: add weekly digest`)
- If nothing to commit: note "nothing to commit" in audit log and continue
- Say: "Implementation committed. Running quality gate..."
- Proceed to Phase 4: Quality Gate (follow CLAUDE.md Phase 4 instructions exactly)

**quality** (or "quality"):
- Verify current state is QUALITY_REVIEWED or IMPLEMENTING
- Write QUALITY_REVIEWED to .ai/sessions/{id}/state
- Append to audit log: "[timestamp] Quality gate override by user"
- Say: "Quality issues acknowledged. Proceeding to PR creation..."
- Proceed to Phase 5: PR Creation

If the approval type doesn't match the current state, explain the mismatch and what state the session is actually in.
If no active session exists, say: "No active session. Start one with /feature, /bugfix, /migration, or /refactor."
