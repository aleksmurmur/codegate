---
name: cg-phase-4
description: Codegate Phase 4 — quality gate and independent review. Use when implementation is complete: commit leftovers, the mechanical checks once, the gate and review sub-agents, fix rounds in a sub-agent limited to what failed.
user-invocable: false
---

# Phase 4 — Quality gate

**Entry**: implementation complete. Session dir: `python3 .claude/scripts/cg_session.py dir` (`{dir}`).
`BASE=$(python3 .claude/scripts/cg_session.py base)` — the merge-base with the task's target branch, taken from
the remote when the local copy is behind it. It fails (the target branch is gone, e.g. a
merged parent of a stacked task was deleted) → stop and ask the user which branch the task
now targets; write it to `{dir}/target-branch`.

Mechanical checks are commands, run once; the gate runs again only after FAIL, and only on
what the fixes touched. Every command's output goes to a file in `{dir}`: read its summary,
not the log. Every fix — for a check, the gate or the review — is done by a **fix sub-agent**:
`.claude/agents/implementer/prompt.md`, given `{dir}`, the task type, the report and the items
to fix. It fixes, commits and returns a short status; the gate and the review never edit code.

**Fix sub-agent results.** `STATUS: done` → check its commits are in `git log`, go on.
`STATUS: question` or `scope` → ask the user (sub-agents cannot), then resume the **same**
sub-agent with the answer (`SendMessage` to its id). A scope result here is a question to the
user, never a change of phase: `{dir}/state` and `{dir}/path` stay — a short-path task does not
go back to the full path after Phase 3. The user declines the wider fix → the finding stays
open and is overridden, accepted or logged as tech debt, as §4 and §5 allow.

## 1. Leftovers

`git status`. Clean → audit `[ts] phase-4-commit: nothing-to-commit`. Otherwise stage this
task's files only (`git add -u` plus new plan files by path; never `-A`/`.`) and commit
`{type}: complete implementation`.

## 2. Mechanical checks — once

All read committed history (`$BASE..HEAD`), not the working tree.

**2a. Tests and diff coverage.** Run the full test suite — the gate's full run; every later
coverage re-check is a full run again. The command is the one the baseline used (Phase 3,
audit line `baseline:`); how it runs is the project's business. Write the failing test
names (or `CLEAN`) to `{dir}/test-results.txt` — the gate compares them with
`test-baseline.txt`. A failing test is not a reason to skip coverage. When the run produces
no coverage report (the stack has no coverage tool), the script falls back to `Mode: grep`:
informational only — say coverage was not measured. Audit
`[ts] coverage-refresh: <command>, coverage <report|none>`.
Then `python3 .claude/scripts/diff-coverage.py --base "$BASE" --output {dir}/coverage-report.md`.
- `0` CLEAN → 2b.
- `1` FAIL → fix sub-agent with `coverage-report.md`: the missing tests (not production code
  bent to the metric), committed; then re-run **coverage only**. A line no test can reach
  (unreachable by construction, a tool artifact) is not a round's work: when only such lines
  are left, escalate at once, each with why it cannot be covered. Up to 3 rounds; then
  escalate: show what is still uncovered; the user says what to do, or accepts it — audit
  `[ts] Coverage accepted by user — N items`, the report goes into the PR description, go on
  to 2b. Audit each FAIL `[ts] Coverage check FAIL — N uncovered items`.
- `2` "report is older than the last commit" → the coverage run did not finish: rebuild the
  report from that run without re-running the tests (the stack's report task), or run it
  again, then re-check.
  Any other `2` (script error) → warn, note in the audit, go on.

**2b. Assertions.** `python3 .claude/scripts/test-assertions.py --base "$BASE" --output {dir}/assertion-report.md`.
- `0` → go on; advisory existence-only findings go to the gate as context.
- `1` → tests touched by this diff assert nothing that could fail: fix sub-agent with
  `assertion-report.md` adds real assertions and commits; re-run this check only. Up to 3
  rounds; then escalate as for coverage (accepted → audit `[ts] Assertions accepted by user —
  N tests`, go on).
- `2` → warn, note, go on.

**2c. Linters and project checks.** `bash .claude/scripts/gate-checks.sh --base "$BASE" --output {dir}/checks-report.md`
runs the linters the project has configured, in check mode — on the changed files where the
tool takes files — and the commands of the option `gate_checks`, each given `CG_BASE` and
`CG_CHANGED_FILES`. A build-tool linter can outlast a foreground tool call: run the script in
the background and wait for it to exit; a check has no time limit — a check cut short is a
check skipped. The report is written only when the run ends.
`0` or `1` → go on: a failure is the gate's to rate, its fix goes through §4. `2` (a usage
error) → fix the call and run it again. No report (the run was cut off) → run it again; the
gate does not start without it. Audit `[ts] gate-checks: <CLEAN|FAIL>`.

## 3. The gate

Inputs, as paths: `$BASE`, the report path, `{dir}` (where `design.md`, `requirements.md`,
`PLAN.md`, `test-baseline.txt`, `test-results.txt`, `coverage-report.md`,
`assertion-report.md`, `checks-report.md` are), `.ai/CODEBASE_CONTEXT.md`, `.ai/tech-debt/`,
the task type. The agent reads the files itself; do not paste them.

The gate writes the report path it is given: `{dir}/QUALITY_REPORT.md`. Before a re-run, copy
the previous report to `{dir}/QUALITY_REPORT-<N>.md` (copy, not move: the shared session
store would bring a moved file back), so the latest verdict is always in
`QUALITY_REPORT.md` and every round stays readable.

Option `gate_mode` (`.claude/scripts/cg-option.sh gate_mode single`):
- `single`: one sub-agent, `.claude/agents/quality-gate/prompt.md`, walks the whole rule list.
- `lenses`: in ONE message, three parallel sub-agents with `.claude/agents/quality-gate/lens.md`,
  each given its lens — `arch`, `security`, `testing` — and the same inputs, each writing
  `{dir}/quality-findings-<lens>.md`. Then one sub-agent with
  `.claude/agents/quality-gate/prompt.md` in merge mode, given those three files, writes the
  report. A missing lens file is noted, not blocking.

Then: state `QUALITY_REVIEWED`; audit `[ts] Quality gate complete`; present the report;
`bash .claude/scripts/notify.sh "Codegate" "Quality gate: {VERDICT}"`.

## 4. Verdict

Severities and what cannot be overridden: `.claude/agents/quality-gate/finding-format.md`.

- **PASS** → audit `[ts] Quality gate passed — verdict: PASS`, go to §5.
- **WARN** → the fix sub-agent fixes the Warnings worth fixing now (not re-gated: the PR/MR
  review sees them); the rest go to tech debt or the PR description. Audit
  `[ts] auto-proceed: phase-4-warn`, §5.
- **FAIL** → note `FIX_BASE=$(git rev-parse HEAD)`; the fix sub-agent fixes every Critical,
  commits `fix: address quality gate findings — round N`, then re-runs the tests listed in
  `test-results.txt` and the fix's own tests and rewrites `test-results.txt` from that run.
  Re-run 2c as it was (the task's `$BASE`) when a check had failed. Then re-run the gate **on the fix
  commits only**: base `$FIX_BASE`, so it judges `$FIX_BASE..HEAD` (its §0 says what a re-run
  judges). A re-run is always one sub-agent in walk mode, whatever `gate_mode`. Up to 3
  rounds; then escalate. Audit `[ts] Quality gate FAIL — N issues`.
  - When the fixes changed production code, re-run diff coverage once after the last round;
    its result goes into the PR description, it does not restart the loop.
  - `/cg-approve quality` by the user overrides FAIL: audit `[ts] Quality gate override by
    user — FAIL items accepted`, §5.
  - A finding marked `[no override]` cannot be overridden. Escalate.

## 5. Independent review

Once the gate has concluded (PASS, WARN, FAIL overridden): a reviewer who did not write the code reads it against the task. It catches what a gate that
shares the author's plan and reasoning does not.

Audit `[ts] Independent review started`. Sub-agent `.claude/agents/independent-review/prompt.md`, given **only**: `{dir}/task.md`,
`{dir}/requirements.md` when it exists, the base `$BASE`, and the report path `{dir}/REVIEW.md`. Not the
plan, the ADRs, the gate report, or your own account of how it was built.
- **CLEAN** → go on.
- **HAS CRITICAL** → each critical is either fixed test-first by the fix sub-agent (commit
  `fix: independent review — <one line>`) or the user says why it does not apply (audit
  their reason). The agent never dismisses a critical alone. Then re-run the
  review on the fix commits only (base = HEAD before the fixes, report `{dir}/REVIEW-N.md`),
  with the tests of the fixed code. Up to 3 rounds; then escalate.
- **HAS WARNINGS ONLY** → the fix sub-agent fixes what is worth fixing now (not
  re-reviewed), the rest goes to the PR description.

Audit `[ts] Independent review: <verdict> — C critical, W warnings`. Then write
`git rev-parse HEAD` to `{dir}/checked-sha` and go to Phase 5 (skill `cg-phase-5`).

`checked-sha` is what the push gate compares against: commits after it that touch more than
`.ai/` block the push until they are checked. Before the PR/MR exists (state still
`QUALITY_REVIEWED` — e.g. changes the PR creator stopped on, committed since) that is this
section again on the new commits, which rewrites `checked-sha`; after it, skill `cg-rework`.

Debug mode: skill `cg-flow-feedback`, Phase 4 block.
