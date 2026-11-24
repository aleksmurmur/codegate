Start a new bug fix task session. Task type: `bugfix`. Raw arguments: $ARGUMENTS

The arguments are the task: its text, or a tracker key (skill `cg-phase-0`). A leftover
`--fast` or `--interactive` flag is dropped from the text: there is one mode.

## Pre-elicitation observability

Before elicitation: if Grafana or ELK MCP servers are configured, query for metrics/errors
related to the bug description and include findings as "Observability context" in the elicitation output.

## Flow

Run Phase 0 (skill `cg-phase-0`), then Phase 1 (skill `cg-phase-1`).

Checklist: `.claude/agents/elicitation/checklists/bugfix.md`
