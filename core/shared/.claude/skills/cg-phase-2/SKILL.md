---
name: cg-phase-2
description: Codegate Phase 2 — planning. Use after elicitation is answered (or /cg-approve elicit): the planning sub-agent writes down the agreed design, a mechanical integrity check, then on to implementation.
user-invocable: false
---

# Phase 2 — Planning

**Entry**: elicitation answered (fast) or `/cg-approve elicit` (interactive).
Session dir: `python3 .claude/scripts/cg_session.py dir` (below: `{dir}`).

The design was decided and critiqued in Phase 1. Planning writes it down as files, tests and
commits; it does not reopen it, so there is no review of the plan's merit here.

1. Write `ELICITED` to `{dir}/state`; audit `[ts] Elicitation approved`.
2. Planning sub-agent: `.claude/agents/planning/prompt.md`, with the task, `design.md`,
   `requirements.md`, `elicitation.md` (the data map and details), CODEBASE_CONTEXT.md.
   Write its plan to `{dir}/PLAN.md`. When it returns **Open decisions** instead of a plan,
   the design left a choice open: ask the user (one question each, with its recommendation),
   record the answers in `requirements.md` and `elicitation.md`, and resume it.
3. Integrity check (deterministic): `python3 .claude/scripts/plan-integrity.py {dir}/PLAN.md`
   → `{dir}/integrity-report.md`. It checks that Modify paths exist, Create paths do not,
   and Flyway versions do not collide. Its findings are warnings for you to fix, not a gate. On `MIRAGES_FOUND` fix the plan yourself
   (edit the line, or re-run planning with the report) and re-run the check once; on
   `PARSE_FAILED` bring the Checklist to the format `[ ] N. Verb path.ext — description`.
   Stop and ask only when the fix changes what the task delivers.
4. Present the plan. Optional: when `ExitPlanMode` is available and `.ai/plan-mode-disabled`
   does not exist, show PLAN.md through it (presentation only; if the user asks for changes,
   re-run planning with their feedback).
5. Mode:
   - `fast`: audit `[ts] fast-mode-auto-proceed: phase-2` and go to Phase 3 (skill
     `cg-phase-3`).
   - `interactive`: "Plan ready. Type `/cg-approve plan` to begin implementation." Wait; no
     source file is written before it.

The plan must include: a numbered Checklist of files (exact paths); tests first, with
scenarios; schema changes with migration versions; optional smoke commands; affected systems
beyond this task; an explicit scope boundary; and, when elicitation named consumers,
a Consumers section — who needs follow-up work, what exactly, and the rollout order.

Debug mode: skill `cg-flow-feedback`, Phase 2 block.
