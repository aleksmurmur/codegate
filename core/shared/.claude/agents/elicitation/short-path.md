# The short path — when a task is small, and when it stops being small

The one statement of these rules; the elicitation agent, the implementer, the phase skills and
the recovery note point here. A small task skips the rounds, the design draft and the plan:
test-first implementation, the quality gate, the independent review, the PR/MR.

## Small

**All** of these hold, checked in the code (find the place with Glob/Grep, read it, grep its
callers), not guessed from the task text:

1. **Clear** — what to do follows from the task and the code; there is no question you would
   have to put to the user.
2. **Nothing expensive to reverse** — no new table, column, API field or endpoint; no change
   to a stored format, an event or another public contract.
3. **One place** — it changes existing behaviour (a fix, an adjustment) in one function,
   class or component and its tests. Not a new feature; not a change its callers must follow.
   A **refactor** qualifies on the same terms: it restructures one function, class or
   component and its callers need no change. A refactor that renames or moves what other code
   uses, or spans several units, is not small.
4. **Not in an excluded area** — the project's option `short_path_excluded` does not cover the
   code it touches.

Any doubt on any of them → not small.

## Outgrown

While the task is being implemented (Phase 3), it stops being small the moment it needs:
- anything condition 2 rules out;
- a question to the user;
- a change in a second place — another function, class or component than `requirements.md`'s
  `## Place` names; a caller that must follow counts.

Then it moves to the full path (skill `cg-phase-3`, "The short path grows").

This applies to Phase 3 only. After it — fixes for the quality gate or the independent review,
rework on the open PR/MR — the task does not go back to the full path: a fix goes wherever its
finding points, and what needs the user's word (a schema or contract change, more scope) is a
question to the user.
