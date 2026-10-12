Start a new feature task session. Task type: `feature`. Raw arguments: $ARGUMENTS

## Mode parsing (before anything else)

Default mode is **fast** (auto-proceed through phase boundaries). Inspect
`$ARGUMENTS` for mode flags:

- `--interactive` present → MODE=interactive. The user has explicitly
  opted into per-phase approval gates.
- `--fast` present (legacy alias; default anyway) → MODE=fast. No-op
  semantically, but recognize it so muscle-memory typing isn't an error.
- Neither flag → MODE=fast (default).
- Both flags present → `--interactive` wins (the more specific intent).

Strip whichever flag(s) appear from the description; the remaining text
is the task.

Examples:
- `/cg-feature add a login button` → task=`add a login button`, MODE=fast
- `/cg-feature --interactive add a login button` → MODE=interactive
- `/cg-feature add a login button --fast` → task=`add a login button`, MODE=fast (explicit but default)
- `/cg-feature ABC-123` → task taken from tracker item ABC-123 (skill `cg-phase-0`)
- `/cg-feature --interactive --fast …` → MODE=interactive

## Flow

Run Phase 0 (skill `cg-phase-0`), then Phase 1 (skill `cg-phase-1`), which writes
`MODE` (one word, `fast` or `interactive`) to the session's `mode` file.

Checklist: `.claude/agents/elicitation/checklists/feature.md`
