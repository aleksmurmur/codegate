Process a phase approval for the current session. Approval type: $ARGUMENTS

Read `.ai/current-session` → session ID. Read `.ai/sessions/{id}/state`. Read `.ai/sessions/{id}/mode` (default `interactive` if missing).

## Fast-mode short-circuit

If `mode=fast`, phase transitions auto-proceed without an approval gate.
A user typing `/cg-approve <phase>` against a fast-mode session has two
possible meanings:

- The user instinctively typed it forgetting the session is fast — most
  common. Respond: "Session is in fast mode — phase `<phase>` already
  auto-proceeded (or will, when it becomes the active phase). No
  approval needed. Use `/cg-status` to see where the session is now."
- The user is overriding a fast-mode escalation point (cannot-override
  FAIL, scope-drift question, mid-impl clarification) — only valid when
  `state=QUALITY_REVIEWED` AND verdict is FAIL AND argument is `quality`.
  In that single case, run the same override path as interactive mode
  (record `Quality gate override by user — FAIL items accepted` and
  proceed to Phase 5). Critical/cannot-override FAILs still cannot be
  overridden — refuse with the standard message.

Everything else below is the interactive-mode dispatch.

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
