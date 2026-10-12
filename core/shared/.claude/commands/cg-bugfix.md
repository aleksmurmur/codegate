Start a new bug fix task session. Task type: `bugfix`. Raw arguments: $ARGUMENTS

## Mode parsing (before anything else)

Default mode is **fast**. Inspect `$ARGUMENTS` for mode flags:

- `--interactive` → MODE=interactive (opt into per-phase approval gates).
- `--fast` → MODE=fast (legacy alias for the default).
- Neither → MODE=fast.
- Both → `--interactive` wins.

Strip the flag(s) from the description.

## Pre-elicitation observability

Before elicitation: if Grafana or ELK MCP servers are configured, query for metrics/errors
related to the bug description and include findings as "Observability context" in the elicitation output.

## Flow

Run Phase 0 (skill `cg-phase-0`), then Phase 1 (skill `cg-phase-1`), which writes
`MODE` (one word, `fast` or `interactive`) to the session's `mode` file.

Checklist: `.claude/agents/elicitation/checklists/bugfix.md`
