# Quality gate rules — common to every stack

The gate walks this file and `.claude/agents/quality-gate/rules-stack.md` (the stack's rules: its
additions to the sections below, and sections of its own). Each section names the lens that owns
it when the gate runs as three lenses; in a single run, one agent walks them all. Severities,
the finding shape and `[no override]` are in `.claude/agents/quality-gate/finding-format.md`.

You report; you never change code, run a formatter in write mode, or commit. Fixes are done
after the gate by another agent, from your report.

## 0. Scope — every lens

- **Inputs**: the range `<base>..HEAD` (the diff and the list of files it touches),
  `.ai/CODEBASE_CONTEXT.md`, the session's `design.md` (when present), `requirements.md` (when
  present), `PLAN.md`, `test-baseline.txt`, `test-results.txt`, `coverage-report.md`,
  `assertion-report.md`, `checks-report.md`, and `.ai/tech-debt/`.
- **Short path** (the session's `path` file reads `short`): a small task built without a plan.
  There is no `PLAN.md` or `design.md`. Wherever a rule reads `PLAN.md`'s Acceptance Criteria
  (`Security:` lines included), read `requirements.md`'s `## Acceptance criteria`; the code
  should stay within its `## Place`. Rules on Design Notes and smoke commands are "not
  applicable", with no "plan predates" Warning; judge design by `CODEBASE_CONTEXT.md` and the
  neighbouring code.
- **Read every touched file in full** before judging it. Several rules ask what the rest of the
  file and its neighbours already do; answering from the diff alone is guessing.
- **A re-run** after a FAIL is given the fix commits only: judge their diff, the files they
  touch, and the paths next to the fixed code (other callers and writers of what changed) — not
  the whole task again.

## 1. Mechanical results — lens: testing

- **Tests.** Compare `test-results.txt` (the gate's full run: failing test names, or `CLEAN`)
  with `test-baseline.txt` (the run before any code). A failure not in the baseline is a
  Critical. When the baseline is `CLEAN` or `NONE` (no run before the task), every failure is
  the task's. Either file missing → say so; do not guess.
- **Checks** (`checks-report.md`: the linters and the project's own checks, already run).
  A failed project check, a compile or type error, or a linter error that breaks the build →
  Critical. Formatting and style violations → one Warning per linter, listing them.
- **Coverage and assertions** (`coverage-report.md`, `assertion-report.md`). Their blocking
  findings were resolved or accepted before you ran; weigh what is left (advisory
  existence-only tests, files the assertion script could not parse, coverage accepted by the
  user) under §7.

## 2. Smoke verification — lens: testing

`PLAN.md`'s "Smoke Verification" section, when it has commands: run each, compare with the
expected outcome. Fails (non-zero exit, connection refused, 4xx/5xx, build error) → Critical;
succeeds with unexpected output → Warning, expected vs actual. No section → "not applicable".
These commands read; one that would write source files or data the task does not own is not
run — say so.

## 3. Who else reads and writes — lens: arch

For every piece of shared data whose meaning or writing the diff changes (the stack file lists
the kinds): find the other code that reads or writes it — grep the name, follow it to its
readers and writers — and check those paths still hold: the old reader that now gets a new
value, the second writer that skips the new rule, the sibling path that returns the same data
unchanged. Report one line per path checked. A broken neighbour is a finding of the section it
falls under.

## 4. Design — lens: arch

- **Against the agreed design.** `design.md` records the decisions, the options weighed and the
  choice ("X instead of Y"). Check the code took the chosen option, and did not drift toward a
  rejected one or decide something the design left to the user. `requirements.md` wins where the
  two disagree. A contradiction → Critical.
- **Against the plan.** `PLAN.md` `### Design Notes`: the code lives where the notes say, owns
  only what they scope, follows the pattern they name. A contradiction (the notes say "does not
  touch X", the diff reaches into X) → Critical; a subtle mismatch → Warning. No Design Notes →
  Warning ("plan predates Design Notes") and judge by `CODEBASE_CONTEXT.md` alone.
- **Should the new thing exist at all.** The design and the plan are the yardstick here, so a
  plan that declared "new component" makes any faithful new component conform. For every new
  unit, search for an existing one that already carries the responsibility: by its public names,
  by the domain nouns in its own name, and by the collaborators it takes — whoever already holds
  them is the likely owner. State what you searched. A second implementation of resolution,
  traversal, caching or validation that existing code in the same area performs → Critical: two
  copies of one rule drift, and the drift surfaces later as two paths disagreeing. On task type
  `refactor` the prior implementation is the thing being replaced: check it is removed instead.
- **Abstractions.** A new interface, base type, wrapper or generic must relieve a pain you can
  name; otherwise it is premature (Warning). Code copied a third time without extraction →
  Warning.
- **Refactor.** The new shape must improve something nameable — testability, a change it
  unlocks. Code only moved → Warning.
- **Boundaries.** A new boundary violation (a cross-domain dependency, logic in a layer that
  should not hold it) not acknowledged in the design or plan → Critical; one that makes an
  existing, recorded violation worse → Warning.

## 5. Conventions — lens: arch

Compare new code with `CODEBASE_CONTEXT.md` (naming, layers, error handling, dependency style,
mapping; the stack file lists what to look at). Contradicts a HIGH-confidence finding without an
explanation → Critical. Deviates from a MEDIUM-confidence finding, or adds a pattern that is not
wrong but inconsistent → Warning. Style alone is not a finding unless a project rule says so.

## 6. Error handling — lens: arch

- New error paths handled, or do they escape as unhandled exceptions? An empty catch that
  swallows an error → Critical.
- Errors logged with enough context (which resource, which action); the project's established
  pattern followed. Missing context on an important operation, an inconsistent error format →
  Warning.

## 7. Tests — lens: testing

Run the stack's grep checks (the stack file) on every changed test file and paste the results
before judging. Then, by reading:

1. **Calculated expected values** — arithmetic inside assertion arguments. Compare against
   literal constants, not a value derived at runtime.
2. **Assertions that cannot discriminate.** Start from `assertion-report.md`'s advisory and
   unparsed lists, then do what a regex cannot: a tautological assertion, an assertion on a
   mock the test itself configured, and above all — **would this test still pass if the
   production change in this diff were reverted?** Name the line of production code each new
   test would catch a regression in. If you cannot, flag it.
3. **Helpers duplicating production** — a non-trivial helper used by assertions that recomputes
   what a production method computes: the helper goes, the production method is used.
4. **Setup in the test body** that belongs in a fixture or before-block.
5. **Scenarios** — the plan's TDD anchor covered; error cases tested (not-found, invalid input,
   boundaries); names that say the scenario.
6. **Isolation** — no order dependency or shared mutable fixture between tests; no real network,
   unseeded randomness, wall-clock or timezone dependence without injection.
7. **Mocking** — a unit test mocking more than three collaborators probably wants to be an
   integration test.

Critical: #1, #2 or #3 unjustified; a stack grep check the stack file rates Critical; a critical
path with new logic completely untested; tests that only check nothing threw. Warning: the rest,
or a violation with a one-line justification in the test.

## 8. Security — lens: security

- **`Security:` acceptance criteria first.** For each line of `PLAN.md`'s
  `### Acceptance Criteria` starting with `Security:`: the constraint it names appears in the
  code, and at least one test exercises it — must-not criteria included, which are the ones
  usually skipped. Unimplemented or untested → Critical. Implemented, tested only shallowly (heavy
  mocks, the must-not path never run end to end) → Warning. No `Security:` lines → Warning
  ("plan predates Security ACs") and the checks below only.
- **Sibling consistency.** When the diff adds a member to an existing file or module — a method,
  route, handler, client call — compare its prologue with its siblings': the annotations,
  guard calls, wrappers, headers and options they all carry. Omitting something every sibling has
  → Critical; the diff owes the explanation, you do not owe an exploit.
- **Is the shared guard a guard.** Follow it to its declaration before crediting it: an action
  that defaults to permitted, a role every user holds, a filter registered for another path make
  a protective-looking line decoration. Copying the annotation without the guard call, and
  copying both where the annotation was never enough, are separate failures.
- **Ownership and tenancy.** An id from the request is checked against the caller's ownership and
  tenant, not only for existence; a new way to act beyond one's role, or to relax a restriction
  on oneself. Missing → Critical.
- **Input** crossing a trust boundary is validated (format, length, range) before it reaches
  logic, and rejected visibly. Used unvalidated → Critical; a silent drop → Warning.
- **Secrets and personal data** hardcoded, or in logs, error responses or telemetry → Critical.
- The stack file adds the stack's own risks. An inconsistent but not clearly wrong auth or
  storage approach → Warning.

## 9. Acceptance criteria — lens: testing

For each criterion in `PLAN.md` `### Acceptance Criteria`: at least one test in the diff that
verifies it, by its name or by asserting the criterion's observable outcome. Uncovered →
Critical. Covered only by a heavily mocked test that never reaches the observable outcome →
Warning. No such section → Warning ("plan predates acceptance criteria").
