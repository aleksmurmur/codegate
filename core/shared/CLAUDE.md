# Agent Workflow System

This project uses a structured coding workflow. Every task follows enforced phases.
Hooks block the agent's Write and Edit tool calls at the wrong phase (Bash-based writes — redirects, `sed -i` — are not intercepted). Follow the workflow, don't try to route around it.

---

## Two Flows

### Flow A: Codebase Context (`/cg-context`)

Run once per project, refresh when architecture changes significantly.
Produces `.ai/CODEBASE_CONTEXT.md`, updates linter configs, seeds tech debt log.
Does NOT create a session. Independent of any task.

### Flow B: Task (`/cg-feature`, `/cg-bugfix`, `/cg-refactor`)

Every task goes through five phases in order. You cannot skip phases.

---

## Session mode

Every task session has a mode, written to `.ai/sessions/{id}/mode` by
the slash-command that started it:

- **`fast`** (default) — the agent auto-proceeds through phase boundaries.
  The user still gets to drive when their input is irreplaceable:
  elicitation Q&A, mid-implementation clarifications, scope-drift
  decisions, and end-of-gate decisions on non-auto-fixable findings.
- **`interactive`** — the agent stops at every phase boundary and waits
  for `/cg-approve {phase}` (or `/ok`). Opt in when you want to inspect
  each artifact before the next phase starts.

The mode is set by passing `--interactive` in `$ARGUMENTS` to
`/cg-feature`, `/cg-bugfix`, or `/cg-refactor`. With no flag (or with
the legacy `--fast` alias), the session is fast. It is **per session**;
a fast session does not become interactive mid-flight (start a fresh
one).

**Backwards compatibility**: sessions started before the mode mechanism
existed don't have a mode file. When the file is missing, treat as
`interactive` — the historical default — to avoid surprising any
in-flight pre-flag sessions. Brand-new sessions started by the current
slash commands always write the file explicitly.

### What changes between modes

| Boundary | interactive | fast |
|---|---|---|
| Elicitation has questions → answers recorded | wait for `/cg-approve elicit` | auto-proceed to Phase 2 |
| Elicitation returns cosmetic fast-path proposal | wait for `/cg-approve quick` or `/cg-approve elicit` | auto-proceed via the `quick` path (implementation only) |
| Plan ready, integrity CLEAN | wait for `/cg-approve plan` | auto-proceed to Phase 3 (after Pattern Review advisory is printed) |
| Plan integrity MIRAGES_FOUND or PARSE_FAILED | STOP, ask user | STOP, ask user — same; a bad plan blocks both modes |
| Implementation complete | wait for `/cg-approve implementation` | auto-proceed to Phase 4 |
| QG verdict PASS | auto-proceed to Phase 5 | auto-proceed to Phase 5 — same |
| QG verdict WARN | wait for `/cg-approve quality` | auto-proceed to Phase 5 |
| QG verdict FAIL, fixable | up to 3 fix rounds, then escalate | up to 3 fix rounds, then escalate — same |
| QG verdict FAIL, **cannot-override** (XSS, hardcoded secret, untested Security AC) | STOP, escalate | STOP, escalate — same |
| Mid-implementation clarifications.md question | STOP, ask user | STOP, ask user — same; user input is irreplaceable |
| Scope drift discovered mid-implementation | STOP, ask user | STOP, ask user — same |

### How phases read the mode

Inside any phase step, when the rule "STOP and wait for /cg-approve X"
appears, first check the mode:

```bash
MODE=$(cat .ai/sessions/{id}/mode 2>/dev/null || echo interactive)
```

If `MODE=fast`: append `[ts] fast-mode-auto-proceed: <phase>` to the
audit log and continue with the next phase's entry steps. Do NOT wait.

If `MODE=interactive`: stop and wait as usual.

The phase-end messages below ("Type `/cg-approve X` to proceed") are
written for interactive mode. In fast mode, the agent should still
present the artifact (plan, quality report, etc.) so the user can read
it after the fact, but not say "type /cg-approve" — say "auto-proceeding
to <next phase>" instead.

---

## Debug mode

Independent of `mode` (fast / interactive). Toggled by the presence of
the marker file `.ai/cg-debug-mode` (sibling of `.ai/sessions/`). Manage
it via `/cg-debug on` / `/cg-debug off` / `/cg-debug` (status), or
`touch .ai/cg-debug-mode` / `rm .ai/cg-debug-mode` directly.

**Purpose**: collect first-hand observations about how the flow itself
performs on a real task — what felt right, what was friction, what
the agent wished it had. Intended for running a real feature with
the explicit goal of evaluating codegate itself.

**Effect**: when the marker exists, at the end of each phase the agent
appends a structured block to `.ai/sessions/{id}/flow-feedback.md`.
The block has four sections, each a short bulleted list (1–4 lines):

```markdown
## Phase N — {Name} ({timestamp})

**Worked well**:
- {observation}

**Friction**:
- {observation}

**Could improve**:
- {observation}

**Missing in flow**:
- {observation}
```

Empty sections may be written as `- (none observed)` rather than
skipped — the structure tells the reader what was looked at vs not.

At the end of Phase 5, the agent additionally writes a session-summary
block aggregating top items across phases:

```markdown
---

## Session summary ({timestamp})

**Top wins**:
- {3–5 bullets, biggest pluses of the run}

**Top pain points**:
- {3–5 bullets, biggest frictions}

**Suggested flow improvements (ranked)**:
1. {concrete change to a runbook step / prompt / script}
2. ...

**Things missing from the flow**:
- {capabilities or guardrails the agent wished existed}
```

**Tone rule**: observations should be specific and actionable, not
abstract. Bad: "elicitation was slow". Good: "elicitation produced 9
questions for a 1-file change — could classify as cosmetic earlier".

**Honesty rule**: if a phase went smoothly, say `- (no friction observed)`
rather than padding. Negative signal is more valuable than filler.

The marker is project-level and persists across sessions; the
flow-feedback file is per-session and accumulates as the session runs.
Sessions started while the marker is absent get no flow-feedback file
at all.

---

## Phase 1: Elicitation

**Entry**: user runs `/cg-feature [description]`, `/cg-bugfix [description]`, or `/cg-refactor [description]`.

Steps:
1. Generate session ID: `$(date +%Y%m%d-%H%M%S)-$(echo "$TASK" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | cut -c1-30)`
2. Create session directory: `.ai/sessions/{id}/`
3. Write task description to `.ai/sessions/{id}/task.md`
4. Write `IDLE` to `.ai/sessions/{id}/state`
5. Write session ID to `.ai/current-session`
6. Append to `.ai/sessions/{id}/audit.log`: `[timestamp] Session started, task type: {type}`
7. If `.ai/CODEBASE_CONTEXT.md` does not exist: warn the user — "No codebase context found. Run `/cg-context` first for best results. Continuing without it."
8. Run elicitation: use the Task tool with the prompt at `.claude/agents/elicitation/prompt.md`, passing the task description, task type, and contents of CODEBASE_CONTEXT.md (if present) and the relevant checklist from `.claude/agents/elicitation/checklists/{type}.md`
9. The elicitation agent returns **either** a fast-path proposal **or** a question list:

   **If the agent returns a fast-path proposal** (cosmetic change only; never for `refactor`):
   - Write the mini-plan section of the proposal to `.ai/sessions/{id}/PLAN.md`
   - Append to audit log: `[timestamp] Fast-path proposed — classification: cosmetic`
   - Present the proposal to the user verbatim
   - **Debug-mode hook**: if `.ai/cg-debug-mode` exists, append a `## Phase 1 — Elicitation` block to `.ai/sessions/{id}/flow-feedback.md` per §Debug mode format (cosmetic classification: was it justified, did the elicitation prompt see signals that should have surfaced earlier).
   - **Mode check** (`cat .ai/sessions/{id}/mode`):
     - `interactive`: say "This change looks cosmetic. Type `/cg-approve quick` to skip elicitation and planning and go straight to implementation, or `/cg-approve elicit` to run the full workflow anyway." **STOP. Wait for `/cg-approve quick` or `/cg-approve elicit`.**
     - `fast`: append `[ts] fast-mode-auto-proceed: phase-1-cosmetic via quick` to audit log. Treat as if the user typed `/cg-approve quick` — proceed directly to Phase 3 (implementation) without Phase 2 planning.

   **If the agent returns a question list** (normal flow):
   - Present the questions to the user. Ask them all at once, not one by one.
   - **Always wait for answers, regardless of mode** — elicitation Q&A is the one user touchpoint fast mode never skips. Record Q&A in `.ai/sessions/{id}/elicitation.md`.
   - **Debug-mode hook**: if `.ai/cg-debug-mode` exists, append a `## Phase 1 — Elicitation` block to `.ai/sessions/{id}/flow-feedback.md` per §Debug mode format (question count vs task size, which questions surfaced real ambiguity vs filler, anything the elicitation checklist should have asked but didn't).
   - **Mode check**:
     - `interactive`: say "Elicitation complete. Review the answers above, then type `/cg-approve elicit` to proceed to planning." **STOP. Do not proceed until user types `/cg-approve elicit`.**
     - `fast`: append `[ts] fast-mode-auto-proceed: phase-1` to audit log. Say "Elicitation complete (answers above). Auto-proceeding to planning." Proceed directly to Phase 2 entry steps.

---

## Phase 2: Planning

**Entry**: user types `/cg-approve elicit`

Steps:
1. Write `ELICITED` to `.ai/sessions/{id}/state`
2. Append to audit log: `[timestamp] Elicitation approved`
3. Run planning sub-agent: Task tool with `.claude/agents/planning/prompt.md`, passing task description + elicitation answers + CODEBASE_CONTEXT.md
4. Write the plan to `.ai/sessions/{id}/PLAN.md`
5. Run the plan integrity check (deterministic, no LLM):
   ```
   python3 .claude/scripts/plan-integrity.py .ai/sessions/{id}/PLAN.md
   ```
   The script checks that every file path in the Checklist exists (for Modify) or does
   not exist yet (for Create). For Flyway projects it also checks that no migration
   version collides with an existing one. Liquibase projects get only the path check
   (no changeset-id parsing in v1). Output is written to
   `.ai/sessions/{id}/integrity-report.md`.
   Exit code: `0` = CLEAN, `1` = MIRAGES_FOUND.
6. If the script exits with **1** (verdict `MIRAGES_FOUND` or `PARSE_FAILED`):
   - Show the report to the user
   - For MIRAGES_FOUND say: "The plan references things that don't exist in the codebase (listed above). The plan must be corrected before it can be approved."
   - For PARSE_FAILED say: "The plan is missing a `## Checklist` heading or its items don't match the expected format (`[ ] N. Verb path.ext — description`). The plan must be corrected."
   - Offer to re-run planning with corrections, or let the user edit PLAN.md manually.
   - **STOP. Do not accept `/cg-approve plan` until the issue is resolved.**
7. If the script exits with **0 (CLEAN)**:
   - If `.ai/CODEBASE_CONTEXT.md` exists, run the pattern review sub-agent (Task tool with `.claude/agents/plan-review/prompt.md`, passing the path to PLAN.md, CODEBASE_CONTEXT.md, and `integrity-report.md`). The agent appends an advisory `## Pattern Review` section to `integrity-report.md`. If CODEBASE_CONTEXT.md is absent, skip this step.
   - Show any warnings from the script to the user (symbols not found, etc.)
   - Show any Pattern Review advisory findings to the user, prefixed with "Advisory (not blocking):"
   - **Native Plan Mode display (optional, soft-fail)**: if the `ExitPlanMode` tool is available in this environment AND `.ai/plan-mode-disabled` does not exist, invoke `ExitPlanMode` with the contents of PLAN.md so the user can review the plan in Claude Code's native Plan Mode UI. Plan Mode is presentation only — `/cg-approve plan` remains the formal approval gate. If the user rejects (exits without approving) or asks for changes, re-dispatch the planning sub-agent with their feedback rather than asking for `/cg-approve plan`. If the tool is unavailable (older Claude Code, headless run, or invocation from a different harness): skip silently and continue with the markdown presentation step below.
   - Present the plan
   - **Debug-mode hook**: if `.ai/cg-debug-mode` exists, append a `## Phase 2 — Planning` block to `.ai/sessions/{id}/flow-feedback.md` per §Debug mode format (plan size vs task complexity, integrity script catches vs misses, pattern review advisory usefulness, anything the planning sub-agent over- or under-thought).
   - **Mode check** (`cat .ai/sessions/{id}/mode`):
     - `interactive`: say "Plan ready. Review it above, then type `/cg-approve plan` to begin implementation." **STOP. Do not write any source files until user types `/cg-approve plan`.**
     - `fast`: append `[ts] fast-mode-auto-proceed: phase-2` to audit log. Say "Plan ready (above). Auto-proceeding to implementation." Proceed directly to Phase 3 entry steps. (Note: a MIRAGES_FOUND or PARSE_FAILED plan stops in both modes — see step 6.)

The plan must include:
- Numbered checklist of files to change/create (exact paths)
- Tests to write first — TDD anchor with specific scenarios
- Database schema changes (if any, with migration version)
- Optional smoke verification commands
- Affected systems beyond this task
- Explicit scope boundary

---

## Phase 3: Implementation

**Entry**: user types `/cg-approve plan`

Steps:
1. Write `PLAN_APPROVED` to `.ai/sessions/{id}/state`
2. Write `IMPLEMENTING` to `.ai/sessions/{id}/state`
3. Append to audit log: `[timestamp] Plan approved, implementation started`
4. Ensure `.ai/sessions/{id}/decisions/` directory exists. Each non-obvious decision lands as its own ADR file there (see step 7 for format).
4a. **Backfill ADRs for elicitation-surfaced trade-offs.** Read
    `.ai/sessions/{id}/elicitation.md`. Any question where the user
    explicitly picked one approach over another with non-trivial
    consequences is a non-obvious decision and gets its own ADR — even
    though it was made *before* implementation. Typical triggers:
    - "Use library X instead of the existing convention Y" (e.g.,
      react-hook-form + zod when the project's existing forms use
      useState; or kotlinx.serialization when Jackson is the convention).
    - "Add a new dependency to do Z" (the user weighed adding the dep
      vs writing inline; capture the rationale).
    - "Diverge from the established pattern for this case because <reason>".
    - "Defer scope X to a follow-up" (an explicit non-goal worth recording).
    Skip elicitation answers that are just clarifications of unambiguous
    behavior (e.g., "what should happen on empty list — return [] vs
    null" with no broader trade-off).
    For each qualifying answer, write an ADR using the format in step 7:
    Decision is the choice, Reasoning quotes the user's stated rationale
    from elicitation, Alternative considered is the option not taken.
    These are written BEFORE the baseline test run in step 5 — if a
    deviation is being formalized, the ADR should pre-date any code.
5. **Run baseline test suite**: run the full test suite now, before writing any code. Save the names of any failing tests to `.ai/sessions/{id}/test-baseline.txt`. If the suite is clean, write "CLEAN" to that file. This baseline is used by the quality gate to distinguish pre-existing failures from new ones introduced by this task.
6. Implement in small commits, one concept per commit. Follow the plan's `### Commit Plan` section — each entry there is one commit. Typical chunk: one test file + the production code it exercises.
   a. **Write the tests first.** Mark the corresponding test items `[x]` in PLAN.md.
   b. **Confirm red with a one-line prediction (desirable, agent's discretion).** If you choose to skip running (e.g., the test references a symbol that doesn't exist yet), append: `[ts] red-check: <test-target> — skipped:<reason>`. Otherwise:
      - Before running, append: `[ts] red-check-predict: <test-target> — expecting "<substring>"`. The substring must come from a real fragment of the error you expect (assertion text, exception name) — not generic "fails".
      - Run the tests, then append: `[ts] red-check-result: <test-target> — <matched|not_matched|test_passed|compile_error|deferred:<reason>>`.
      - `matched` → proceed. It means the test ran and failed at the assertion, for the reason predicted.
      - `compile_error` → the run died before the test executed: unresolved reference, import error, collection error. **Never record this as `matched`**, even when the predicted substring does appear in the output. `unresolved reference: SiteService` is a genuine fragment of a genuine error and says nothing about the assertion, which never ran; logging it as `matched` writes confidence into the audit trail that the run does not support, which is worse than logging nothing. Add the minimal stubs permitted below, re-run, and record that second result.
      - `not_matched` or `test_passed` → investigate before committing the test — it likely isn't exercising the intended path.
      - `deferred` → only when running becomes infeasible mid-run (e.g., infra dropped); don't use as a default escape.
      - Red for the right reason is necessary, not sufficient: a test asserting only that nothing threw goes red against a stub that throws, and stays green forever after. Phase 4's assertion check blocks those, but it is cheaper to not write them.
   c. **Commit the tests.** Stage only the test files from this chunk's checklist by explicit path — never `git add -A` or `git add .`. The working tree may hold unrelated untracked files (other tickets' docs, `.mcp.json`, `.ai/audit`, editor scratch) that must not enter this branch's history. `git add <test-paths> && git commit -m "test: <description>"`. Append to audit.log: `[ts] commit: {sha} — test: <description>`.
   d. **Write the production code** to make the tests pass. Mark the corresponding production items `[x]` in PLAN.md.
   e. **Commit the implementation.** Stage only this chunk's production files by explicit path (same rule as c — no `git add -A`/`git add .`): `git add <prod-paths> && git commit -m "{type}: <description>"` where `{type}` matches the task (`feat`/`fix`/`refactor`). Append to audit.log.
   f. **Optional refactor** (no behavior change). Commit: `git commit -m "refactor: <description>"`. Append to audit.log.

   When tests cannot compile without minimal production stubs (typed languages — Kotlin, Go, Rust, etc.): include the minimal stubs in the test commit, and note in audit.log `[ts] test-commit-includes-stubs: <reason>`. Stubs must be plumbing only (signatures, empty methods that throw or return defaults) — never business logic.
7. **When making a non-obvious decision** (choosing between approaches, deviating from a pattern, working around a gotcha): create a new ADR file `.ai/sessions/{id}/decisions/NNN-slug.md` where `NNN` is the next zero-padded sequence number (`001`, `002`, …) and `slug` is a short kebab-case summary:
   ```
   # {Short title}

   **Date**: {timestamp}
   **Decision**: {what was decided}
   **Reasoning**: {why}
   **Alternative considered**: {what else was possible}
   ```
   One ADR per decision — keeps git history granular (one ADR = one commit) and lets `/cg-resume` match ADR filenames against plan steps. Non-obvious means: a senior developer reading the diff would wonder "why did they do it this way?"
8. **When you have a clarification question that does NOT affect scope** (the plan is silent on a small detail, two valid interpretations exist with no real trade-off, codebase reality contradicts a tiny assumption): append the question to `.ai/sessions/{id}/clarifications.md` as a timestamped Q&A block:
   ```
   ## [timestamp] {Short title}
   **Question**: {what's unclear}
   **Why it matters**: {what depends on the answer}
   ```
   Present the question to the user and **STOP**. When the user answers, append `**Resolved**: {answer}` to the same block before continuing. Persisting the exchange survives compaction and lands the rationale in the PR narrative alongside elicitation answers.
9. **If you discover something not in the plan that significantly affects scope**: STOP immediately. Explain what you found. Ask whether to update the plan before continuing. Do not silently expand scope.
10. **Maximum 3 fix iterations**: if the quality gate or reviewer finds issues and you have already made 3 rounds of fixes without resolving them, stop and escalate to the user. Do not loop indefinitely.
11. When done: append to audit log: `[timestamp] Implementation complete`.
11a. **Debug-mode hook**: if `.ai/cg-debug-mode` exists, append a `## Phase 3 — Implementation` block to `.ai/sessions/{id}/flow-feedback.md` per §Debug mode format (commit chunking matched plan or drifted, red-check discipline helpful or noise, ADRs generated or missed, scope drift vs surfaced clarifications, anything the agent had to invent because the plan was silent).
12. **Mode check** (`cat .ai/sessions/{id}/mode`):
    - `interactive`: say "Implementation complete. Type `/cg-approve implementation` to run the quality gate." **STOP. Do not proceed until user types `/cg-approve implementation`.**
    - `fast`: append `[ts] fast-mode-auto-proceed: phase-3` to audit log. Say "Implementation complete. Auto-proceeding to quality gate." Proceed directly to Phase 4 entry steps.

---

## Phase 4: Quality Gate

**Entry**: user types `/cg-approve implementation`

Steps:
1. **Commit any uncommitted leftover.** Phase 3 should have committed in chunks; this catches anything missed.
   - Run `git status`. If clean, skip and append to audit.log: `[ts] phase-4-commit: nothing-to-commit`.
   - If there are uncommitted changes: stage only this task's files — `git add -u` for modifications to already-tracked files, plus any new files from the plan checklist by explicit path. Do not `git add -A`/`git add .` (unrelated untracked files must stay out of the branch). Then `git commit -m "{type}: complete implementation"`. Append to audit.log.
2. **Mechanical pre-gate checks.** Two of them, both running before the quality-gate
   agent, both reading committed history rather than the working tree. Coverage answers
   "did this line run"; assertions answer "would anything have noticed if it were
   wrong". A test whose body is `assertDoesNotThrow { ... }` passes the first and
   fails the second, which is the whole reason the second exists.

   2a. **Diff coverage**:
   - Compute base: `BASE=$(git merge-base main HEAD)`
   - **Refresh coverage data first.** `diff-coverage.py` reads existing
     coverage reports; if none exist it falls back to a weak grep symbol
     check. To get real coverage, detect the project's coverage command
     and run it now:
     - `package.json` with `vitest` in deps → `npx vitest run --coverage`
       (or `npm test -- --run --coverage`). Emits `coverage/coverage-final.json`.
     - `package.json` with `jest` in deps → `npx jest --coverage`. Emits
       `coverage/coverage-final.json` (Istanbul default) or `coverage/lcov.info`.
     - `build.gradle*` with JaCoCo → `./gradlew test jacocoTestReport`. Emits
       `build/reports/jacoco/test/jacocoTestReport.xml`.
     - `pom.xml` with `jacoco-maven-plugin` → `mvn test`.
     - No coverage tool detected (or detection ambiguous): skip this sub-step.
       `diff-coverage.py` will fall through to grep and report `Mode: grep`;
       treat that report as informational, not authoritative — flag it in
       the audit so the user knows coverage was not actually measured.
     Append: `[ts] coverage-refresh: <command|skipped:reason>`.
   - Run: `python3 .claude/scripts/diff-coverage.py --base "$BASE" --output .ai/sessions/{id}/coverage-report.md`
   - **Note**: diff-coverage diffs committed history (`$BASE..HEAD`), not the working tree. If you revert or edit a file to address a finding, commit that change before re-running — otherwise the report reflects the last commit, not your working tree, and the "fixed → re-run" loop will look stuck.
   - Exit **0 (CLEAN)**: continue to 2b.
   - Exit **1 (FAIL)**: do NOT run the quality-gate agent. Present the coverage report to the user. Say: "Coverage check failed — new production code isn't exercised by tests (details above). Add tests, commit, then run `/cg-approve implementation` again." Append to audit log: `[timestamp] Coverage check FAIL — N uncovered items`. STOP.
   - Exit **2 (script error)**: warn the user and continue to 2b; note in audit log.

   2b. **Test assertions**:
   - Run: `python3 .claude/scripts/test-assertions.py --base "$BASE" --output .ai/sessions/{id}/assertion-report.md`
   - The script examines only test functions containing a line this diff added, and
     abstains (reporting the file as `unparsed`) rather than guessing when it cannot
     delimit a language's test functions. Both are deliberate: it should be quiet
     enough that a finding means something.
   - Exit **0 (CLEAN)**: continue to step 3. The report may still list advisory
     existence-only findings — pass them to the gate as context, do not block on them.
   - Exit **1 (FAIL)**: do NOT run the quality-gate agent. Present the report to the user. Say: "Assertion check failed — tests touched by this diff assert nothing that could fail (details above). They would pass with the code under test replaced by a stub. Add real assertions, commit, then run `/cg-approve implementation` again." Append to audit log: `[timestamp] Assertion check FAIL — N tests assert nothing`. STOP.
   - Exit **2 (script error)**: warn the user and continue to step 3; note in audit log.
3. Run quality gate. The flow branches on `.ai/multi-persona-qg-enabled` marker.

   **Inputs common to both branches.** Alongside the diff, pass the list of files the
   diff touches, and tell the agent to read each of them in full before reviewing.
   A unified diff shows changed lines plus a few lines of context; the defects that
   are hardest to catch do not live there. A new method that omits a guard every
   sibling applies, a second copy of machinery that already exists elsewhere, a
   declaration three files away that makes an annotation permissive — all are
   invisible in a diff and obvious in the file. Reading the touched files is the
   floor, not the ceiling: when a check asks whether something already exists or
   how siblings behave, follow the symbol out of the file.

   3a. **Default (marker absent) — single sub-agent**:
       Task tool with `.claude/agents/quality-gate/prompt.md`, passing the git diff
       since the baseline commit, the list of files the diff touches, CODEBASE_CONTEXT.md,
       path to PLAN.md, path to `test-baseline.txt`, path to `coverage-report.md`, and
       path to `.ai/tech-debt/`. The sub-agent writes QUALITY_REPORT.md.

   3b. **Multi-persona (marker present)**:
       In a SINGLE message dispatch three Task calls in parallel:
         - `.claude/agents/quality-gate-security/prompt.md`
         - `.claude/agents/quality-gate-arch-code/prompt.md`
         - `.claude/agents/quality-gate-testing/prompt.md`
       Each receives the same inputs as 3a. Each writes its findings to
       `.ai/sessions/{id}/quality-findings-{security|arch-code|testing}.md`.
       Parallel dispatch matters — sequential dispatch wastes wall-clock for
       no benefit.

       After all three return (or the runtime determines which finished),
       dispatch synthesis as a separate Task call:
       `.claude/agents/quality-gate-synthesis/prompt.md`, passing paths to
       all three findings files plus PLAN.md and the diff. Synthesis writes
       QUALITY_REPORT.md directly in the same format as the single-pass.

       If any findings file is missing (a lens failed): synthesis notes the
       absence in the report and proceeds with the available files; do not
       block the gate on a single missing lens.
4. Write quality report to `.ai/sessions/{id}/QUALITY_REPORT.md`
5. Write `QUALITY_REVIEWED` to `.ai/sessions/{id}/state`
6. Append to audit log: `[timestamp] Quality gate complete`
7. Present `QUALITY_REPORT.md` to the user. Then run `bash .claude/scripts/notify.sh "Codegate" "Quality gate: {VERDICT}"` so the user sees the result if they switched away during the gate (terminal bell + OS toast where available; silent on headless / unsupported environments).
7a. **Debug-mode hook**: if `.ai/cg-debug-mode` exists, append a `## Phase 4 — Quality Gate` block to `.ai/sessions/{id}/flow-feedback.md` per §Debug mode format (which dimensions caught real issues vs which produced noise, false positives, false negatives the agent noticed itself, coverage refresh effectiveness, lens overlap or gaps in the multi-persona case, total wall-clock time vs perceived value).
8. If verdict is **PASS**: say "Quality gate passed. Proceeding to PR creation." Append to audit log: `[timestamp] Quality gate passed — verdict: PASS`. Proceed to Phase 5 automatically. (Same in both modes.)
9. If verdict is **WARN**: present the warnings.
   - **Mode check** (`cat .ai/sessions/{id}/mode`):
     - `interactive`: say "Quality gate passed with warnings (listed above). Type `/cg-approve quality` to proceed, or fix the warnings first." Do not proceed until user responds.
     - `fast`: append `[ts] fast-mode-auto-proceed: phase-4-warn` to audit log. Say "Quality gate passed with warnings (listed above). Auto-proceeding to PR creation." Proceed to Phase 5.
10. If verdict is **FAIL**: explain each FAIL item. Fix them. After each fix round: commit the fixes (`fix: address quality gate findings — round N`), then re-run quality gate. Up to 3 rounds total. If FAILs remain after round 3, escalate to user. Append to audit log: `[timestamp] Quality gate FAIL — N issues, awaiting fix`. (Same loop in both modes.)
   - If user explicitly overrides with `/cg-approve quality`: append `[timestamp] Quality gate override by user — FAIL items accepted`. Then proceed to Phase 5.
   - Critical SQL and security FAILs cannot be overridden. **Even in fast mode** — XSS, hardcoded secret, untested Security AC, and similar cannot-override findings always escalate to the user.

---

## Phase 5: PR Creation

**Entry**: quality gate passed (or overridden with `/cg-approve quality`)

Steps:
1. Run PR creator sub-agent: Task tool with `.claude/agents/pr-creator/prompt.md`
2. PR description must include:
   - What was built and why (from task + elicitation)
   - Summary of elicitation answers (the accepted requirements)
   - Key decisions from `decisions/` ADR files (non-obvious choices reviewers should know about)
   - Quality report summary
3. Write `PR_CREATED` to `.ai/sessions/{id}/state`
4. Append to audit log: `[timestamp] PR created: {url}`
5. **Debug-mode hook**: if `.ai/cg-debug-mode` exists:
   - First append a `## Phase 5 — PR Creation` block to `.ai/sessions/{id}/flow-feedback.md` per §Debug mode format (PR description completeness, sub-agent took the right inputs, anything the PR creator had to guess).
   - Then append the **session summary** block per §Debug mode format. Read the four prior Phase blocks already in `flow-feedback.md` and aggregate: top 3–5 wins, top 3–5 pain points, ranked concrete suggested improvements, gaps the agent encountered. Tell the user one line: "Flow feedback recorded at `.ai/sessions/{id}/flow-feedback.md`."

---

## Slash Command Handlers

- `/cg-context` — run the CIE sub-agent (`.claude/agents/codebase-intelligence/prompt.md`). No session needed. Output: `.ai/CODEBASE_CONTEXT.md`.
- `/cg-feature [description]` — task type `feature`. Begin Phase 1.
- `/cg-bugfix [description]` — task type `bugfix`. Begin Phase 1.
- `/cg-refactor [description]` — task type `refactor`. Begin Phase 1.
- `/cg-approve {quick|elicit|plan|implementation|quality}` — phase transitions. See `.claude/commands/cg-approve.md` for the state-by-state behaviour.
- `/ok [phase]` — context-aware shortcut for `/cg-approve`. With no argument: reads session state and dispatches the right approval. With argument: identical to `/cg-approve <arg>`. See `.claude/commands/ok.md`. Refuses to override quality FAIL — long form required for that.
- `/cg-status` — read `.ai/current-session`; report session ID, task, state, and next action. If no session: "No active session."
- `/cg-explain` — read-only inspector: state + recent audit + checklist progress + diff so far. See `.claude/commands/cg-explain.md`. No side effects, no state advance.
- `/cg-timeline [--since DURATION] [--full]` — cross-session chronological view across `.ai/sessions/*`. See `.claude/commands/cg-timeline.md`.
- `/cg-debt` — list `.ai/tech-debt/*.md` with severity. If empty: "No tech debt logged."
- `/cg-debug [on|off]` — toggle the project-level `.ai/cg-debug-mode` marker. With no argument: report current status. See `.claude/commands/cg-debug.md` and §Debug mode.

State transitions in order: `IDLE → ELICITED → PLAN_APPROVED → IMPLEMENTING → QUALITY_REVIEWED → PR_CREATED`. State file: `.ai/sessions/{id}/state`. Current-session pointer: `.ai/current-session`.

---

## Hard Rules

1. Never write source files when state is IDLE or ELICITED. (Hooks enforce this, but don't attempt it.)
2. Never expand scope beyond the approved plan without asking the user first.
3. Never create a PR without a completed quality gate.
4. Always log state transitions to `.ai/sessions/{id}/audit.log` with a timestamp.
5. Writes to `.ai/` are always allowed regardless of state — that is where session data lives.
6. If the user asks you to skip a phase: explain why the phase exists, then ask if they still want to skip. If yes, document the skip in the audit log.
7. **Respond in the user's language.** If the user writes in Russian, respond in Russian. If in English, respond in English. Match the language of the user's most recent message. This applies to all responses, questions, and status messages throughout the workflow.
8. **When uncertain during implementation, ask — do not assume.** If something in the plan is ambiguous, two valid approaches exist with real trade-offs, or codebase reality contradicts what elicitation assumed: stop and ask the user before proceeding. Do not pick an interpretation silently. Small technical choices (variable names, method signatures) may go to a `decisions/` ADR; anything affecting behavior, API shape, data model, or user-visible output must be raised with the user first.
