---
name: cg-phase-1
description: Codegate Phase 1 — open the task session and run elicitation (data map, a design draft a fresh critic reads before the user sees it, rounds of at most 4 questions, architecture and business never mixed, then a summary of what is settled). Use right after Phase 0 created the task branch.
user-invocable: false
---

# Phase 1 — Session and elicitation

**Entry**: Phase 0 put the task on its own branch.

## Open the session

0. `python3 .claude/scripts/cg_session.py current` prints a session that is not MERGED or
   ABANDONED → the branch already belongs to an open task: Phase 0 did not reach the new
   branch. Stop and report; create nothing.
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
   task type, the language the user writes in, CODEBASE_CONTEXT.md if present, and the checklist
   `.claude/agents/elicitation/checklists/{type}.md`. It returns a **fast-path proposal**
   (cosmetic change), a **round** of questions, or **Elicitation complete**.

### Fast-path proposal (cosmetic; never for `refactor`)

- Write its mini-plan to `PLAN.md`; audit `[ts] Fast-path proposed — classification: cosmetic`.
- `fast`: audit `[ts] fast-mode-auto-proceed: phase-1-cosmetic via quick`, write
  `IMPLEMENTING`, and go to Phase 3 (skill `cg-phase-3`) without planning.
- `interactive`: present it; "Type `/cg-approve quick` to go straight to implementation, or
  `/cg-approve elicit` for the full workflow." Wait.

### A round

- Append the round to `elicitation.md` under its `## Round N — <track>` heading: the message,
  then the file part (data map, backlog). Show the user only the message. Audit
  `[ts] Elicitation round N: <track>, K questions`.
- Wait for the answer, in either mode — rounds are the one boundary fast mode never skips.
  "All as recommended", "as recommended except N: …" and "decide the rest yourself" are
  complete answers. Record each answer under its question in `elicitation.md`.
  A non-answer ("not sure", "TBD") gets the concrete options with their cost and one
  question "1, 2 or 3?" — never carried into the next round open.
- The next round: resume the same sub-agent with the answers (`SendMessage` to its id, when
  the harness has it) — it keeps the code it has read. Otherwise dispatch it again with
  `elicitation.md` as the previous rounds.
- A split proposal: the user decides. On a split, write the first part as `task.md` (the
  original goes under `## Original task` in it), list the other parts in `elicitation.md`
  under `## Split off`, tell the user to start each as its own task later, audit
  `[ts] Task split: <parts>`, and continue elicitation on the first part.

### The design draft — critique before the user sees the design

Once per task (not for a fast-path), before the first architecture round or the completion,
the sub-agent returns a **design draft**. The user sees nothing of it yet.

1. Write the draft (from its `# Design` heading) to `{dir}/design.md`; audit
   `[ts] Design draft written`.
2. Design critic sub-agent: `.claude/agents/design-critic/prompt.md`, with the paths of
   `task.md`, `design.md` and CODEBASE_CONTEXT.md when present. Only those — never
   `elicitation.md` or the conversation. Append its `## Critique` section to `design.md`;
   audit `[ts] Design critique: N findings (B blockers)`.
3. Resume the elicitation sub-agent with the critique (as for a round's answers). It returns
   `## Critique dispositions`: append them, and the `## Design (updated)` sections when it
   sends them, to `design.md`; audit `[ts] Critique dispositions: adopted X, declined Y,
   asked Z`. Its next output — a round or the completion — is handled as usual.

Resuming after an interruption: `design.md` without `## Critique` → step 2; with it but
without `## Critique dispositions` → step 3.

### Elicitation complete

- `design.md` must exist unless the task went through the fast-path; if it does not, the
  sub-agent skipped Step 5.5 — send it back for the draft.
- When the completion has `### Design (updated)`, append it to `design.md`.
- Write its Requirements part to `{dir}/requirements.md` — the file exists only once
  elicitation is complete; `/ok` and `/cg-approve elicit` read it as that. The independent
  review in Phase 4 reads it instead of `elicitation.md`. Append the summary to
  `elicitation.md`; audit `[ts] Elicitation complete — N rounds`.
- Show the summary message. `fast`: audit `[ts] fast-mode-auto-proceed: phase-1`, say "Going
  ahead with the above — say if anything is wrong." and go to Phase 2 (skill `cg-phase-2`).
  `interactive`: "Type `/cg-approve elicit` to plan." Wait.

Answers that pick one approach over another with real consequences become ADRs in Phase 3
(step "backfill"). The "consumers and rollout order" answer feeds the plan's Consumers
section and, in Phase 5, the linked tasks for those consumers.

Debug mode (`.ai/cg-debug-mode` exists): skill `cg-flow-feedback`, Phase 1 block.
