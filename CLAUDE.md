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
   - Say: "This change looks cosmetic. Type `/cg-approve quick` to skip elicitation and planning and go straight to implementation, or `/cg-approve elicit` to run the full workflow anyway."
   - **STOP. Wait for `/cg-approve quick` or `/cg-approve elicit`.**

   **If the agent returns a question list** (normal flow):
   - Present the questions to the user. Ask them all at once, not one by one.
   - Wait for answers. Record Q&A in `.ai/sessions/{id}/elicitation.md`
   - Say: "Elicitation complete. Review the answers above, then type `/cg-approve elicit` to proceed to planning."
   - **STOP. Do not proceed until user types `/cg-approve elicit`.**

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
   - Present the plan
   - Say: "Plan ready. Review it above, then type `/cg-approve plan` to begin implementation."
8. **STOP. Do not write any source files until user types `/cg-approve plan`.**

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
4. Create `.ai/sessions/{id}/decisions.md` with header:
   ```
   # Decisions — {task description}
   Session: {id}
   ```
5. **Run baseline test suite**: run the full test suite now, before writing any code. Save the names of any failing tests to `.ai/sessions/{id}/test-baseline.txt`. If the suite is clean, write "CLEAN" to that file. This baseline is used by the quality gate to distinguish pre-existing failures from new ones introduced by this task.
6. Implement in small commits, one concept per commit. Follow the plan's `### Commit Plan` section — each entry there is one commit. Typical chunk: one test file + the production code it exercises.
   a. **Write the tests first.** Mark the corresponding test items `[x]` in PLAN.md.
   b. **Confirm red with a one-line prediction (desirable, agent's discretion).** If you choose to skip running (e.g., the test references a symbol that doesn't exist yet), append: `[ts] red-check: <test-target> — skipped:<reason>`. Otherwise:
      - Before running, append: `[ts] red-check-predict: <test-target> — expecting "<substring>"`. The substring must come from a real fragment of the error you expect (assertion text, exception name) — not generic "fails".
      - Run the tests, then append: `[ts] red-check-result: <test-target> — <matched|not_matched|test_passed|deferred:<reason>>`.
      - `matched` → proceed. `not_matched` or `test_passed` → investigate before committing the test — it likely isn't exercising the intended path. `deferred` → only when running becomes infeasible mid-run (e.g., infra dropped); don't use as a default escape.
   c. **Commit the tests.** `git add -A && git commit -m "test: <description>"`. Append to audit.log: `[ts] commit: {sha} — test: <description>`.
   d. **Write the production code** to make the tests pass. Mark the corresponding production items `[x]` in PLAN.md.
   e. **Commit the implementation.** `git add -A && git commit -m "{type}: <description>"` where `{type}` matches the task (`feat`/`fix`/`refactor`). Append to audit.log.
   f. **Optional refactor** (no behavior change). Commit: `git commit -m "refactor: <description>"`. Append to audit.log.

   When tests cannot compile without minimal production stubs (typed languages — Kotlin, Go, Rust, etc.): include the minimal stubs in the test commit, and note in audit.log `[ts] test-commit-includes-stubs: <reason>`. Stubs must be plumbing only (signatures, empty methods that throw or return defaults) — never business logic.
7. **When making a non-obvious decision** (choosing between approaches, deviating from a pattern, working around a gotcha): append to `decisions.md`:
   ```
   ## [timestamp] {Short title}
   **Decision**: {what was decided}
   **Reasoning**: {why}
   **Alternative considered**: {what else was possible}
   ```
   Non-obvious means: a senior developer reading the diff would wonder "why did they do it this way?"
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
12. Say: "Implementation complete. Type `/cg-approve implementation` to run the quality gate."
13. **STOP. Do not proceed until user types `/cg-approve implementation`.**

---

## Phase 4: Quality Gate

**Entry**: user types `/cg-approve implementation`

Steps:
1. **Commit any uncommitted leftover.** Phase 3 should have committed in chunks; this catches anything missed.
   - Run `git status`. If clean, skip and append to audit.log: `[ts] phase-4-commit: nothing-to-commit`.
   - If there are uncommitted changes: `git add -A && git commit -m "{type}: complete implementation"`. Append to audit.log.
2. **Diff-coverage check** (mechanical, runs before the agent):
   - Compute base: `BASE=$(git merge-base main HEAD)`
   - Run: `python3 .claude/scripts/diff-coverage.py --base "$BASE" --output .ai/sessions/{id}/coverage-report.md`
   - Exit **0 (CLEAN)**: continue to step 3.
   - Exit **1 (FAIL)**: do NOT run the quality-gate agent. Present the coverage report to the user. Say: "Coverage check failed — new production code isn't exercised by tests (details above). Add tests, commit, then run `/cg-approve implementation` again." Append to audit log: `[timestamp] Coverage check FAIL — N uncovered items`. STOP.
   - Exit **2 (script error)**: warn the user and continue to step 3; note in audit log.
3. Run quality gate sub-agent: Task tool with `.claude/agents/quality-gate/prompt.md`, passing the git diff since the baseline commit, CODEBASE_CONTEXT.md, path to PLAN.md, path to `test-baseline.txt`, path to `coverage-report.md`, and path to `.ai/tech-debt/`
4. Write quality report to `.ai/sessions/{id}/QUALITY_REPORT.md`
5. Write `QUALITY_REVIEWED` to `.ai/sessions/{id}/state`
6. Append to audit log: `[timestamp] Quality gate complete`
7. Present `QUALITY_REPORT.md` to the user. Then run `bash .claude/scripts/notify.sh "Codegate" "Quality gate: {VERDICT}"` so the user sees the result if they switched away during the gate (terminal bell + OS toast where available; silent on headless / unsupported environments).
8. If verdict is **PASS**: say "Quality gate passed. Proceeding to PR creation." Append to audit log: `[timestamp] Quality gate passed — verdict: PASS`. Proceed to Phase 5 automatically.
9. If verdict is **WARN**: present the warnings, say "Quality gate passed with warnings (listed above). Type `/cg-approve quality` to proceed, or fix the warnings first." Do not proceed until user responds.
10. If verdict is **FAIL**: explain each FAIL item. Fix them. After each fix round: commit the fixes (`fix: address quality gate findings — round N`), then re-run quality gate. Up to 3 rounds total. If FAILs remain after round 3, escalate to user. Append to audit log: `[timestamp] Quality gate FAIL — N issues, awaiting fix`.
   - If user explicitly overrides with `/cg-approve quality`: append `[timestamp] Quality gate override by user — FAIL items accepted`. Then proceed to Phase 5.
   - Critical SQL and security FAILs cannot be overridden.

---

## Phase 5: PR Creation

**Entry**: quality gate passed (or overridden with `/cg-approve quality`)

Steps:
1. Run PR creator sub-agent: Task tool with `.claude/agents/pr-creator/prompt.md`
2. PR description must include:
   - What was built and why (from task + elicitation)
   - Summary of elicitation answers (the accepted requirements)
   - Key decisions from `decisions.md` (non-obvious choices reviewers should know about)
   - Quality report summary
3. Write `PR_CREATED` to `.ai/sessions/{id}/state`
4. Append to audit log: `[timestamp] PR created: {url}`

---

## Slash Command Handlers

- `/cg-context` — run the CIE sub-agent (`.claude/agents/codebase-intelligence/prompt.md`). No session needed. Output: `.ai/CODEBASE_CONTEXT.md`.
- `/cg-feature [description]` — task type `feature`. Begin Phase 1.
- `/cg-bugfix [description]` — task type `bugfix`. Begin Phase 1.
- `/cg-refactor [description]` — task type `refactor`. Begin Phase 1.
- `/cg-approve {quick|elicit|plan|implementation|quality}` — phase transitions. See `.claude/commands/cg-approve.md` for the state-by-state behaviour.
- `/cg-status` — read `.ai/current-session`; report session ID, task, state, and next action. If no session: "No active session."
- `/cg-debt` — list `.ai/tech-debt/*.md` with severity. If empty: "No tech debt logged."

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
8. **When uncertain during implementation, ask — do not assume.** If something in the plan is ambiguous, two valid approaches exist with real trade-offs, or codebase reality contradicts what elicitation assumed: stop and ask the user before proceeding. Do not pick an interpretation silently. Small technical choices (variable names, method signatures) may go to `decisions.md`; anything affecting behavior, API shape, data model, or user-visible output must be raised with the user first.
