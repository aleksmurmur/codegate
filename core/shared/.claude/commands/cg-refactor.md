Start a new refactor task session. Task type: `refactor`. Raw arguments: $ARGUMENTS

## Mode parsing (before anything else)

Inspect `$ARGUMENTS` for a `--fast` token. If present:
- Strip it from the description (the remaining text is the task).
- Remember `MODE=fast` for step 6 below.
Otherwise: `MODE=interactive`.

## Flow

Run Phase 1 (Elicitation) per CLAUDE.md §Phase 1. After step 5 of Phase 1
(write session id to `.ai/current-session`), also:

6. Write `MODE` (one word, `fast` or `interactive`) to
   `.ai/sessions/{id}/mode`. See CLAUDE.md §Session mode.

Checklist: `.claude/agents/elicitation/checklists/refactor.md`
