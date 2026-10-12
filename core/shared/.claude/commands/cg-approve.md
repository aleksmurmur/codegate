Process a phase approval for the current session. Approval type: $ARGUMENTS

Find this checkout's session: `python3 .claude/scripts/cg_session.py dir` → `.ai/sessions/{id}`. Read its `state`. Read `.ai/sessions/{id}/mode` (default `interactive` if missing — backwards-compat for pre-mode sessions; brand-new sessions always write the file).

## Default-mode short-circuit (fast)

Fast is the default mode for new sessions, so most `/cg-approve` typing
hits a session that has already auto-proceeded. Two scenarios:

- The user instinctively typed `/cg-approve <phase>` forgetting fast
  is the default — most common. Respond: "Session is in fast mode
  (default) — phase `<phase>` already auto-proceeded (or will, when it
  becomes the active phase). No approval needed. Use `/cg-status` to
  see where the session is now."
- The user is overriding an escalation point that fast mode could not
  resolve autonomously (cannot-override FAIL, scope-drift, mid-impl
  clarification) — only valid when `state=QUALITY_REVIEWED` AND verdict
  is FAIL AND argument is `quality`. In that single case, run the same
  override path as interactive mode (record `Quality gate override by
  user — FAIL items accepted`, write `git rev-parse HEAD` to the session's `checked-sha`, and
  proceed to Phase 5). Critical /
  cannot-override FAILs still cannot be overridden — refuse with the
  standard message.

Everything else below is the interactive-mode dispatch (only reached
when the user explicitly opted in via `--interactive`).

| Argument | Required state | Transition | Then |
|---|---|---|---|
| `quick` | IDLE (fast-path proposal pending) | → IMPLEMENTING | Run Phase 3 (skill `cg-phase-3`, fast-path) |
| `elicit` | IDLE | → ELICITED | Run Phase 2 (skill `cg-phase-2`) |
| `plan` | ELICITED | → PLAN_APPROVED → IMPLEMENTING | Run Phase 3 (skill `cg-phase-3`) |
| `implementation` | IMPLEMENTING | (no state change yet) | Run Phase 4 (skill `cg-phase-4`) |
| `quality` | QUALITY_REVIEWED | (accept WARN / override FAIL) | Write `git rev-parse HEAD` to `checked-sha` — the push gate requires it — then run Phase 5 (skill `cg-phase-5`) |

For each transition: write the new state to `.ai/sessions/{id}/state`, append to audit log with timestamp.

If the argument doesn't match the current state: explain the mismatch and what the user should do instead.
If no active session: say "No active session. Start one with /cg-feature, /cg-bugfix, or /cg-refactor."
