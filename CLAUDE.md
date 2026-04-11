# Agent Workflow System

This project uses a structured coding workflow. Every task follows enforced phases.
Hooks physically block file writes at the wrong phase — do not attempt to work around them.

---

## Two Flows

### Flow A: Codebase Context (`/context`)

Run once per project, refresh when architecture changes significantly.
Produces `.ai/CODEBASE_CONTEXT.md`, updates linter configs, seeds tech debt log.
Does NOT create a session. Independent of any task.

### Flow B: Task (`/feature`, `/bugfix`, `/migration`, `/refactor`)

Every task goes through five phases in order. You cannot skip phases.

---

## Phase 1: Elicitation

**Entry**: user runs `/feature [description]`, `/bugfix [description]`, etc.

Steps:
1. Generate session ID: `$(date +%Y%m%d-%H%M%S)-$(echo "$TASK" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | cut -c1-30)`
2. Create session directory: `.ai/sessions/{id}/`
3. Write task description to `.ai/sessions/{id}/task.md`
4. Write `IDLE` to `.ai/sessions/{id}/state`
5. Write session ID to `.ai/current-session`
6. Append to `.ai/sessions/{id}/audit.log`: `[timestamp] Session started, task type: {type}`
7. If `.ai/CODEBASE_CONTEXT.md` does not exist: warn the user — "No codebase context found. Run `/context` first for best results. Continuing without it."
8. Run elicitation: use the Task tool with the prompt at `.claude/agents/elicitation/prompt.md`, passing the task description, task type, and contents of CODEBASE_CONTEXT.md (if present) and the relevant checklist from `.claude/agents/elicitation/checklists/{type}.md`
9. Present the elicitation questions to the user. Ask them all at once, not one by one.
10. Wait for answers. Record Q&A in `.ai/sessions/{id}/elicitation.md`
11. Say: "Elicitation complete. Review the answers above, then type `/approve elicit` to proceed to planning."
12. **STOP. Do not proceed until user types `/approve elicit`.**

---

## Phase 2: Planning

**Entry**: user types `/approve elicit`

Steps:
1. Write `ELICITED` to `.ai/sessions/{id}/state`
2. Append to audit log: `[timestamp] Elicitation approved`
3. Run planning sub-agent: Task tool with `.claude/agents/planning/prompt.md`, passing task description + elicitation answers + CODEBASE_CONTEXT.md
4. Write the plan to `.ai/sessions/{id}/PLAN.md`
5. Run plan integrity check: Task tool with `.claude/agents/plan-integrity/prompt.md`, passing the path to PLAN.md and CODEBASE_CONTEXT.md
6. If integrity check returns **MIRAGES_FOUND**:
   - Show the mirages to the user
   - Say: "The plan references things that don't exist in the codebase (listed above). The plan must be corrected before it can be approved. I can re-run planning with corrections, or you can edit PLAN.md manually."
   - **STOP. Do not accept `/approve plan` until mirages are resolved.**
7. If integrity check returns **CLEAN** (or only warnings):
   - Show any warnings to the user
   - Present the plan
   - Say: "Plan ready. Review it above, then type `/approve plan` to begin implementation."
8. **STOP. Do not write any source files until user types `/approve plan`.**

The plan must include:
- Numbered checklist of files to change/create (exact paths)
- Tests to write first — TDD anchor with specific scenarios
- Database schema changes (if any, with migration version)
- Optional smoke verification commands
- Affected systems beyond this task
- Explicit scope boundary

---

## Phase 3: Implementation

**Entry**: user types `/approve plan`

Steps:
1. Write `PLAN_APPROVED` to `.ai/sessions/{id}/state`
2. Write `IMPLEMENTING` to `.ai/sessions/{id}/state`
3. Append to audit log: `[timestamp] Plan approved, implementation started`
4. Create `.ai/sessions/{id}/decisions.md` with header:
   ```
   # Decisions — {task description}
   Session: {id}
   ```
5. Implement following the plan exactly. Follow the TDD anchor — write the specified tests first, then implement.
6. Mark checklist items `[x]` in PLAN.md as completed.
7. **When making a non-obvious decision** (choosing between approaches, deviating from a pattern, working around a gotcha): append to `decisions.md`:
   ```
   ## [timestamp] {Short title}
   **Decision**: {what was decided}
   **Reasoning**: {why}
   **Alternative considered**: {what else was possible}
   ```
   Non-obvious means: a senior developer reading the diff would wonder "why did they do it this way?"
8. **If you discover something not in the plan that significantly affects scope**: STOP immediately. Explain what you found. Ask whether to update the plan before continuing. Do not silently expand scope.
9. **Maximum 3 fix iterations**: if the quality gate or reviewer finds issues and you have already made 3 rounds of fixes without resolving them, stop and escalate to the user. Do not loop indefinitely.
10. When done: append to audit log: `[timestamp] Implementation complete`
11. Say: "Implementation complete. Running quality gate..."
12. Proceed to Phase 4 automatically.

---

## Phase 4: Quality Gate

**Entry**: automatic after Phase 3 completes, or triggered by `post-stop.sh` hook

Steps:
1. Run quality gate sub-agent: Task tool with `.claude/agents/quality-gate/prompt.md`, passing the git diff and CODEBASE_CONTEXT.md
2. Write quality report to `.ai/sessions/{id}/QUALITY_REPORT.md`
3. Write `QUALITY_REVIEWED` to `.ai/sessions/{id}/state`
4. Append to audit log: `[timestamp] Quality gate complete`
5. Present `QUALITY_REPORT.md` to the user
6. If FAIL items exist: explain each one, ask the user how to proceed. Do not create PR until FAILs are resolved or user explicitly overrides with `/approve quality`
7. If only WARN or PASS: say "Quality gate passed. Ready to create PR."
8. Proceed to Phase 5.

---

## Phase 5: PR Creation

**Entry**: quality gate passed (or overridden with `/approve quality`)

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

**`/context`**
Run the CIE sub-agent (Task tool, `.claude/agents/codebase-intelligence/prompt.md`).
No session needed. Output goes to `.ai/CODEBASE_CONTEXT.md`.

**`/feature [description]`**
Task type: `feature`. Begin Phase 1.

**`/bugfix [description]`**
Task type: `bugfix`. Begin Phase 1.

**`/migration [description]`**
Task type: `migration`. Begin Phase 1.

**`/refactor [description]`**
Task type: `refactor`. Begin Phase 1.

**`/approve elicit`**
Transition from Phase 1 to Phase 2. Write `ELICITED` to state file. Proceed to planning.

**`/approve plan`**
Transition from Phase 2 to Phase 3. Write `PLAN_APPROVED` then `IMPLEMENTING`. Proceed to implementation.

**`/approve quality`**
Override WARN-level quality issues. Write `QUALITY_REVIEWED`. Proceed to Phase 5.

**`/status`**
Read `.ai/current-session`. Report: session ID, task description, current state, what action is needed next.
If no active session: say "No active session."

**`/debt`**
List all `.ai/tech-debt/*.md` files. Show filename, one-line summary of each issue, and severity.
If empty: say "No tech debt logged."

---

## State File Reference

State file location: `.ai/sessions/{id}/state`
Current session pointer: `.ai/current-session`

Valid states in order:
```
IDLE → ELICITED → PLAN_APPROVED → IMPLEMENTING → QUALITY_REVIEWED → PR_CREATED
```

---

## Hard Rules

1. Never write source files when state is IDLE or ELICITED. (Hooks enforce this, but don't attempt it.)
2. Never expand scope beyond the approved plan without asking the user first.
3. Never create a PR without a completed quality gate.
4. Always log state transitions to `.ai/sessions/{id}/audit.log` with a timestamp.
5. Writes to `.ai/` are always allowed regardless of state — that is where session data lives.
6. If the user asks you to skip a phase: explain why the phase exists, then ask if they still want to skip. If yes, document the skip in the audit log.
