Start a new refactor task session. Task type: `refactor`. Raw arguments: $ARGUMENTS

## Mode parsing (before anything else)

Default mode is **fast**. Inspect `$ARGUMENTS` for mode flags:

- `--interactive` → MODE=interactive (opt into per-phase approval gates).
- `--fast` → MODE=fast (legacy alias for the default).
- Neither → MODE=fast.
- Both → `--interactive` wins.

Strip the flag(s) from the description.

## Flow

Run Phase 1 (Elicitation) per CLAUDE.md §Phase 1. After step 5 of Phase 1
(write session id to `.ai/current-session`), also:

6. Write `MODE` (one word, `fast` or `interactive`) to
   `.ai/sessions/{id}/mode`. See CLAUDE.md §Session mode.

Checklist: `.claude/agents/elicitation/checklists/refactor.md`
