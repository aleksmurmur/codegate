---
name: cg-phase-2
description: Codegate Phase 2 — planning. Use after elicitation is answered (or /cg-approve elicit): planning sub-agent, plan integrity check, pattern review, then on to implementation.
user-invocable: false
---

# Phase 2 — Planning

**Entry**: elicitation answered (fast) or `/cg-approve elicit` (interactive).
Session dir: `python3 .claude/scripts/cg_session.py dir` (below: `{dir}`).

1. Write `ELICITED` to `{dir}/state`; audit `[ts] Elicitation approved`.
2. Planning sub-agent: `.claude/agents/planning/prompt.md`, with the task, `elicitation.md`
   (answers and the data map), CODEBASE_CONTEXT.md. Write its plan to `{dir}/PLAN.md`.
3. Integrity check (deterministic): `python3 .claude/scripts/plan-integrity.py {dir}/PLAN.md`
   → `{dir}/integrity-report.md`. It checks that Modify paths exist, Create paths do not,
   and Flyway versions do not collide. Its findings are warnings for you to fix, not a gate. On `MIRAGES_FOUND` fix the plan yourself
   (edit the line, or re-run planning with the report) and re-run the check once; on
   `PARSE_FAILED` bring the Checklist to the format `[ ] N. Verb path.ext — description`.
   Stop and ask only when the fix changes what the task delivers.
4. Pattern review sub-agent: `.claude/agents/plan-review/prompt.md`, with PLAN.md,
   integrity-report.md and CODEBASE_CONTEXT.md when present (run it without the context
   file too: its prior-art check reads the repository). It appends `## Pattern Review` to
   integrity-report.md. `PRIOR ART:` findings name something that already does what the plan
   builds — this is the cheapest moment to act on them.
5. Present the plan. Optional: when `ExitPlanMode` is available and `.ai/plan-mode-disabled`
   does not exist, show PLAN.md through it (presentation only; if the user asks for changes,
   re-run planning with their feedback).
6. Mode:
   - `fast`: decide each pattern-review finding — adopt it (edit PLAN.md) or decline it with
     an ADR in `decisions/` — audit `[ts] fast-mode-auto-proceed: phase-2 — N findings,
     M adopted`, keep the list for the PR description, and go to Phase 3 (skill
     `cg-phase-3`). Ask only when a finding would change what the task delivers (drop, merge
     or add a deliverable) — that is the user's scope decision.
   - `interactive`: "Plan ready. Type `/cg-approve plan` to begin implementation." Wait; no
     source file is written before it.

The plan must include: a numbered Checklist of files (exact paths); tests first, with
scenarios; schema changes with migration versions; optional smoke commands; affected systems
beyond this task; an explicit scope boundary; and, when elicitation named consumers,
`## Consumers` — who needs follow-up work, what exactly, and the rollout order.

Debug mode: skill `cg-flow-feedback`, Phase 2 block.
