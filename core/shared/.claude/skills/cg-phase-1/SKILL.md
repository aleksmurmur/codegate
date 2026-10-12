---
name: cg-phase-1
description: Codegate Phase 1 — open the task session and run elicitation (data map, then one message with the shape of the solution, business questions and the trivia already decided). Use right after Phase 0 created the task branch.
user-invocable: false
---

# Phase 1 — Session and elicitation

**Entry**: Phase 0 put the task on its own branch.

## Open the session

1. Id: `$(date +%Y%m%d-%H%M%S)-<slug>` — the slug Phase 0 made for the branch (`[a-z0-9-]`, cut to
   30 chars). Never the raw task text: a `/` in it would split the session into directories
   that no longer resolve.
2. `.ai/sessions/{id}/`, and in it:
   - `task.md` — the task text (from the tracker item when Phase 0 took one);
   - `branch` — `git branch --show-current`. This binds the session to the branch: hooks,
     commands and the push gate find the session through it;
   - `target-branch` — where the PR/MR goes (Phase 0); `ticket` — the key, if any;
   - `mode` — `fast` or `interactive` (the starting command decides);
   - `tracker.json` — `{"id", "key", "url"}` when Phase 0 created or took an item;
   - `state` — `IDLE`.
3. `audit.log`: `[ts] Session started, task type: {type}`, `[ts] Branch {name} from {target}`,
   and `[ts] Tracker item {key} created` (or `taken`) when there is one.
4. `python3 .claude/scripts/cg_session.py sync` — the shared copy exists from the start.
5. No `.ai/CODEBASE_CONTEXT.md` → say once: "No codebase context; `/cg-context` would help.
   Continuing without it."

## Elicitation

6. Run the elicitation sub-agent: `.claude/agents/elicitation/prompt.md`, with the task text,
   task type, CODEBASE_CONTEXT.md if present, and the checklist
   `.claude/agents/elicitation/checklists/{type}.md`. It returns either a **fast-path
   proposal** (cosmetic change) or an **elicitation message** with its data map.

### Fast-path proposal (cosmetic; never for `refactor`)

- Write its mini-plan to `PLAN.md`; audit `[ts] Fast-path proposed — classification: cosmetic`.
- `fast`: audit `[ts] fast-mode-auto-proceed: phase-1-cosmetic via quick`, write
  `IMPLEMENTING`, and go to Phase 3 (skill `cg-phase-3`) without planning.
- `interactive`: present it; "Type `/cg-approve quick` to go straight to implementation, or
  `/cg-approve elicit` for the full workflow." Wait.

### Elicitation message

- Write everything the agent returned — data map, shape options, questions, decided trivia —
  to `elicitation.md`. Show the user only the message itself (three blocks, see the
  elicitation prompt); the data map stays in the file unless a question refers to it.
- **Block 2 has questions, or block 1 asks the user to choose**: wait for the answer,
  in either mode — this is the one boundary fast mode never skips. "All as recommended
  except N" is a complete answer. Record answers under each question in `elicitation.md`,
  and the settled outcome — one line per answered question, plus the chosen shape — in
  `{dir}/requirements.md`: what was decided, not why or how. The independent review in
  Phase 4 reads it instead of the elicitation file.
  A non-answer ("not sure", "TBD") gets the concrete options with their cost and one
  question "1, 2 or 3?" — never carried into planning open.
- **No questions** (block 1 states its choice, block 2 is empty): write the shape line to
  `{dir}/requirements.md` in either mode. `fast` — say "No business questions; going ahead
  with the shape above — say if it is wrong." and continue at once; `interactive` — wait for
  `/cg-approve elicit`.
- `fast` after answers: audit `[ts] fast-mode-auto-proceed: phase-1` and go to Phase 2
  (skill `cg-phase-2`). `interactive`: "Type `/cg-approve elicit` to plan." Wait.

Answers that pick one approach over another with real consequences become ADRs in Phase 3
(step "backfill"). The "consumers and rollout order" answer feeds the plan's `## Consumers`
section and, in Phase 5, the linked tasks for those consumers.

Debug mode (`.ai/cg-debug-mode` exists): skill `cg-flow-feedback`, Phase 1 block.
