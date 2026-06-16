Start a new feature task session. Task type: `feature`. Raw arguments: $ARGUMENTS

## Mode parsing (before anything else)

Inspect `$ARGUMENTS` for a `--fast` token. If present:
- Strip it from the description (the remaining text is the task).
- Remember `MODE=fast` for step 6 below.
Otherwise: `MODE=interactive`.

Examples:
- `/cg-feature add a login button` → task=`add a login button`, MODE=interactive
- `/cg-feature --fast add a login button` → task=`add a login button`, MODE=fast
- `/cg-feature add a login button --fast` → task=`add a login button`, MODE=fast

## Flow

Run Phase 1 (Elicitation) per CLAUDE.md §Phase 1. After step 5 of Phase 1
(write session id to `.ai/current-session`), also:

6. Write `MODE` (one word, `fast` or `interactive`) to
   `.ai/sessions/{id}/mode`. This is the durable session-mode marker
   read by every later phase transition; see CLAUDE.md §Session mode.

Checklist: `.claude/agents/elicitation/checklists/feature.md`
