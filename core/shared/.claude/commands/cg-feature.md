Start a new feature task session. Task type: `feature`. Raw arguments: $ARGUMENTS

The arguments are the task: its text, or a tracker key (`/cg-feature ABC-123` — the task is
taken from that item, skill `cg-phase-0`). A leftover `--fast` or `--interactive` flag is
dropped from the text: there is one mode.

## Flow

Run Phase 0 (skill `cg-phase-0`), then Phase 1 (skill `cg-phase-1`).

Checklist: `.claude/agents/elicitation/checklists/feature.md`
