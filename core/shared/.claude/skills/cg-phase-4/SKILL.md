---
name: cg-phase-4
description: Codegate Phase 4 — quality gate and independent review. Use when implementation is complete (or /cg-approve implementation): commit leftovers, diff coverage and assertion checks once, the review sub-agent, fix rounds limited to what failed.
user-invocable: false
---

# Phase 4 — Quality gate

**Entry**: implementation complete. Session dir: `python3 .claude/scripts/cg_session.py dir` (`{dir}`).
`BASE=$(git merge-base "$(cat {dir}/target-branch 2>/dev/null || .claude/scripts/cg-option.sh base_branch main)" HEAD)`.

Mechanical checks run once; the gate runs again only after FAIL, and only on what the fixes
touched: fix commits get their own review.

## 1. Leftovers

`git status`. Clean → audit `[ts] phase-4-commit: nothing-to-commit`. Otherwise stage this
task's files only (`git add -u` plus new plan files by path; never `-A`/`.`) and commit
`{type}: complete implementation`.

## 2. Mechanical checks — once

Both read committed history (`$BASE..HEAD`), not the working tree.

**2a. Diff coverage.** Run the full test suite with coverage — the gate's full run; every later
coverage re-check is a full run again. The project's command is the option `test_command`
(`.claude/scripts/cg-option.sh test_command`); how it runs is the project's business. Without the option, detect: vitest `npx vitest run --coverage`; jest
`npx jest --coverage`; Gradle + JaCoCo `./gradlew test jacocoTestReport`; Maven `mvn test`.
None detected → skip, and the script falls back to `Mode: grep` (informational only — say
coverage was not measured). A failing test is not a reason to skip coverage: write the failing test names (or
`CLEAN`) to `{dir}/test-results.txt` — the gate compares them with `test-baseline.txt` —
and still produce the report. Audit `[ts] coverage-refresh: <command|skipped:reason>`.
Then `python3 .claude/scripts/diff-coverage.py --base "$BASE" --output {dir}/coverage-report.md`.
- `0` CLEAN → 2b.
- `1` FAIL → write the missing tests (not production code bent to the metric), commit, and
  re-run **coverage only**. Up to 3 rounds; then escalate. Audit `[ts] Coverage check FAIL — N uncovered items`.
- `2` "report is older than the last commit" → the coverage run did not finish: rebuild the
  report from that run without re-running the tests (the stack's report task), or run it
  again, then re-check.
  Any other `2` (script error) → warn, note in the audit, go on.

**2b. Assertions.** `python3 .claude/scripts/test-assertions.py --base "$BASE" --output {dir}/assertion-report.md`.
- `0` → go on; advisory existence-only findings go to the gate as context.
- `1` → tests touched by this diff assert nothing that could fail: add real assertions,
  commit, re-run this check only. Up to 3 rounds; then escalate.
- `2` → warn, note, go on.

## 3. The gate

Inputs: the diff `$BASE..HEAD`, the list of files it touches (the agent reads each in full —
the defects hardest to catch are invisible in a diff: a guard every sibling applies and the
new method omits, a second copy of existing machinery), CODEBASE_CONTEXT.md, PLAN.md,
`test-baseline.txt`, `test-results.txt`, `coverage-report.md`, `assertion-report.md`,
`.ai/tech-debt/`.

The gate writes the report path it is given: `{dir}/QUALITY_REPORT.md`. Before a re-run, move
the previous report to `{dir}/QUALITY_REPORT-<N>.md`, so the latest verdict is always in
`QUALITY_REPORT.md` and every round stays readable.

- Default: one sub-agent, `.claude/agents/quality-gate/prompt.md`.
- `.ai/multi-persona-qg-enabled` exists: in ONE message, three parallel sub-agents
  (`quality-gate-security`, `quality-gate-arch-code`, `quality-gate-testing`), each writing
  `{dir}/quality-findings-<lens>.md`; then `quality-gate-synthesis` writes the report (a missing
  lens is noted, not blocking). Lenses run no tools: before synthesis, run the gate prompt's
  Stage 2 (linters) and Stage 3 (smoke) yourself and pass their results to synthesis.

Then: state `QUALITY_REVIEWED`; audit `[ts] Quality gate complete`; present the report;
`bash .claude/scripts/notify.sh "Codegate" "Quality gate: {VERDICT}"`.

## 4. Verdict

- **PASS** → audit `[ts] Quality gate passed — verdict: PASS`, go to §5. Both modes.
- **WARN** → fix what is worth fixing now (these fixes are not re-gated: the PR/MR review sees
  them), log the rest as tech debt or in the PR description. `fast`: audit
  `[ts] fast-mode-auto-proceed: phase-4-warn`, §5. `interactive`:
  "Type `/cg-approve quality` to proceed." Wait.
- **FAIL** → fix each FAIL item; commit `fix: address quality gate findings — round N`;
  re-run the gate **on the fix commits only**: their diff, the files they touch, and the
  sibling paths of the fixed code (other callers and writers of what was changed). Not the
  whole task again. Before it, re-run the tests listed in `test-results.txt` and the fix's
  own tests, and rewrite `test-results.txt` from that run — the gate judges test failures
  by that file. Up to 3 rounds; then escalate. Audit `[ts] Quality gate FAIL — N issues`.
  - When the fixes changed production code, re-run diff coverage once after the last round;
    its result goes into the PR description, it does not restart the loop.
  - `/cg-approve quality` by the user overrides FAIL: audit `[ts] Quality gate override by
    user — FAIL items accepted`, §5.
  - Cannot be overridden, in any mode: critical SQL and security findings (XSS, hardcoded
    secret, an untested Security AC). Escalate.

## 5. Independent review

Once the gate has concluded (PASS, WARN accepted, FAIL overridden), in both modes: a
reviewer who did not write the code reads it against the task. It catches what a gate that
shares the author's plan and reasoning does not.

Sub-agent `.claude/agents/independent-review/prompt.md`, given **only**: `{dir}/task.md`,
`{dir}/requirements.md` when it exists, the base `$BASE`, and the report path `{dir}/REVIEW.md`. Not the
plan, the ADRs, the gate report, or your own account of how it was built.
- **CLEAN** → go on.
- **HAS CRITICAL** → each critical is either fixed test-first (commit
  `fix: independent review — <one line>`) or the user says why it does not apply (audit
  their reason). The agent never dismisses a critical alone, in any mode. Then re-run the
  review on the fix commits only (base = HEAD before the fixes, report `{dir}/REVIEW-N.md`),
  with the tests of the fixed code. Up to 3 rounds; then escalate.
- **HAS WARNINGS ONLY** → `fast`: fix what is worth fixing now (not re-reviewed), the rest
  goes to the PR description. `interactive`: show them; "fix or proceed?" — wait.

Audit `[ts] Independent review: <verdict> — C critical, W warnings`. Then write
`git rev-parse HEAD` to `{dir}/checked-sha` and go to Phase 5 (skill `cg-phase-5`).

`checked-sha` is what the push gate compares against: commits after it that touch more than
`.ai/` block the push until they are checked (skill `cg-rework`).

Debug mode: skill `cg-flow-feedback`, Phase 4 block.
