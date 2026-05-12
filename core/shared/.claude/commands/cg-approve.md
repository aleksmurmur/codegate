Process a phase approval for the current session. Approval type: $ARGUMENTS

Read `.ai/current-session` → session ID. Read `.ai/sessions/{id}/state`.

| Argument | Required state | Transition | Then |
|---|---|---|---|
| `quick` | IDLE (fast-path proposal pending) | → IMPLEMENTING | Run Phase 3 per CLAUDE.md §Phase 3 (fast-path) |
| `elicit` | IDLE | → ELICITED | Run Phase 2 per CLAUDE.md §Phase 2 |
| `plan` | ELICITED | → PLAN_APPROVED → IMPLEMENTING | Run Phase 3 per CLAUDE.md §Phase 3 |
| `implementation` | IMPLEMENTING | (no state change yet) | Run Phase 4 per CLAUDE.md §Phase 4 |
| `quality` | QUALITY_REVIEWED | (override) | Run Phase 5 per CLAUDE.md §Phase 5 |

For each transition: write the new state to `.ai/sessions/{id}/state`, append to audit log with timestamp.

If the argument doesn't match the current state: explain the mismatch and what the user should do instead.
If no active session: say "No active session. Start one with /cg-feature, /cg-bugfix, or /cg-refactor."
