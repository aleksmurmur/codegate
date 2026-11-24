---
name: cg-phase-2
description: Codegate Phase 2 — planning. Use after elicitation is answered: the planning sub-agent writes down the agreed design, a mechanical integrity check, then on to implementation.
user-invocable: false
---

# Phase 2 — Planning

**Entry**: elicitation answered.
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
   → `{dir}/integrity-report.md`. Exit 1 blocks implementation until it passes:
   `MIRAGES_FOUND` — a Modify or Delete path that does not exist, a Create path that does,
   colliding Flyway versions, fewer than 3 acceptance criteria, or a Commit Plan that does not
   cover every Checklist item exactly once; `PARSE_FAILED` — no `## Checklist`, or no item in
   the format `[ ] N. Verb path.ext — description`. Fix the plan yourself (edit the line, or
   re-run planning with the report) and re-run the check. Its warnings — symbols not found,
   a created name that already exists, missing Design Notes or `Security:` criteria — do not
   block: fix what is real. Stop and ask only when a fix changes what the task delivers.
4. Present the plan. Optional: when `ExitPlanMode` is available and `.ai/plan-mode-disabled`
   does not exist, show PLAN.md through it (presentation only; if the user asks for changes,
   re-run planning with their feedback).
5. Audit `[ts] auto-proceed: phase-2` and go to Phase 3 (skill `cg-phase-3`).

The plan must include: a numbered Checklist of files (exact paths); tests first, with
scenarios; schema changes with migration versions; optional smoke commands; affected systems
beyond this task; an explicit scope boundary; and, when elicitation named consumers,
a Consumers section — who needs follow-up work, what exactly, and the rollout order.

Debug mode: skill `cg-flow-feedback`, Phase 2 block.
