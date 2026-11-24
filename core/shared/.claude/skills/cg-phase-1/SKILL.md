---
name: cg-phase-1
description: Codegate Phase 1 — open the task session; a small task the user confirms takes the short path (straight to test-first implementation), any other runs elicitation (data map, a design draft a fresh critic reads before the user sees it, rounds of at most 4 questions, architecture and business never mixed, then a summary of what is settled). Use right after Phase 0 created the task branch.
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
   - `tracker.json` — `{"id", "key", "url"}` when Phase 0 created or took an item;
   - `state` — `IDLE`.
3. `audit.log`: `[ts] Session started, task type: {type}`, `[ts] Branch {name} from {target}`,
   and `[ts] Tracker item {key} created` (or `taken`) when there is one.
4. `python3 .claude/scripts/cg_session.py sync` — the shared copy exists from the start.
5. No `.ai/CODEBASE_CONTEXT.md` → say once: "No codebase context; `/cg-context` would help.
   Continuing without it."

## Elicitation

6. Run the elicitation sub-agent: `.claude/agents/elicitation/prompt.md`, with the task text,
   task type, the language the user writes in, CODEBASE_CONTEXT.md if present, the checklist
   `.claude/agents/elicitation/checklists/{type}.md`, and the areas the project never treats as
   small (`.claude/scripts/cg-option.sh short_path_excluded`; no output = none). It returns a
   **short-path proposal** (a small task), a **round** of questions, or **Elicitation complete**.

### Short path — a small task

The sub-agent judged the task small (`.claude/agents/elicitation/short-path.md`, "Small") and
returned `## Short path`.

1. Write its whole output to `{dir}/short-path.md`; audit `[ts] Short path proposed: <why>`.
2. Show the user its message — one line saying why, and the acceptance criteria — and wait:
   the user's word decides.
3. **Yes** (any agreement, or `/ok`): write its Requirements part to `{dir}/requirements.md`
   and `short` to `{dir}/path`; audit `[ts] Short path confirmed by user`; go to Phase 3
   (skill `cg-phase-3`). No rounds, no design draft, no PLAN.md.
   A correction to a criterion is a yes with that change: amend `short-path.md` first.
4. **No**: write `full` to `{dir}/path`; audit `[ts] Short path declined by user`; resume the
   sub-agent (or dispatch it again) with **Known so far** — `short-path.md` and "the user
   wants the full path". It goes on from its Step 1.

### After the short path grew

Phase 3 sends a short-path task back here when it turned out bigger (state `IDLE`,
`{dir}/path` = `full`, the reason in the audit log). Dispatch the sub-agent as in step 6, plus
**Known so far**: `short-path.md`, the reason, and the commits already on the branch
(`git log --oneline $(python3 .claude/scripts/cg_session.py base)..HEAD`). From there Phase 1
runs as for any task; its completion overwrites `requirements.md`.

### A round

- Append the round to `elicitation.md` under its `## Round N — <track>` heading: the message,
  then the file part (data map, backlog). Show the user only the message. Audit
  `[ts] Elicitation round N: <track>, K questions`.
- Wait for the answer — rounds are a boundary that never proceeds by itself.
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

Once per task (not on the short path), before the first architecture round or the completion,
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

- `design.md` must exist; if it does not, the sub-agent skipped Step 5.5 — send it back for
  the draft.
- When the completion has `### Design (updated)`, append it to `design.md`.
- Write its Requirements part to `{dir}/requirements.md`. The independent review in Phase 4
  reads it instead of `elicitation.md`. Append the completion to `elicitation.md`, its
  `## Elicitation complete` heading included — `/ok` reads that heading as "complete"; audit `[ts] Elicitation complete — N rounds`.
- Show the summary message, audit `[ts] auto-proceed: phase-1`, say "Going ahead with the
  above — say if anything is wrong." and go to Phase 2 (skill `cg-phase-2`).

Answers that pick one approach over another with real consequences become ADRs in Phase 3
(step "backfill"). The "consumers and rollout order" answer feeds the plan's Consumers
section and, in Phase 5, the linked tasks for those consumers.

Debug mode (`.ai/cg-debug-mode` exists): skill `cg-flow-feedback`, Phase 1 block.
