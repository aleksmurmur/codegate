# codegate

A Claude Code configuration template that enforces a structured coding workflow.
Designed for teams where non-senior developers use AI agents to write code.

## What it does

Every task follows enforced phases before code reaches review:

1. **Elicitation** — context-aware clarifying questions before any planning
2. **Plan approval** — human reviews and approves a plan before any files are written
3. **Implementation** — code written against the approved plan
4. **Quality gate** — automated review: tests, linters, LLM review across 7 dimensions
5. **PR creation** — branch, commit, PR with quality report attached

Hooks physically block file writes at wrong phases — the agent cannot bypass them.

## Install

Copy into your project root:

```
CLAUDE.md
.claude/
```

Add to your `.gitignore` (session data is ephemeral; codebase context and tech debt are kept):

```
.ai/sessions/
.ai/current-session
```

Python 3 must be available for hook JSON parsing (standard on Linux/Mac).

## Usage

### First time in a project

```
/cg-context
```

Explores your project, produces `.ai/CODEBASE_CONTEXT.md`, logs pre-existing issues to `.ai/tech-debt/`.
Commit `CODEBASE_CONTEXT.md` so your team shares the same baseline.

### Starting a task

```
/cg-feature add date filter to the results page
/cg-bugfix  users can't log in after password reset
/cg-refactor extract payment logic into its own service
```

Answer the elicitation questions, then follow the prompts.

### Phase approvals

```
/cg-approve elicit          # after answering elicitation questions
/cg-approve plan            # after reviewing the generated plan
/cg-approve implementation  # commits changes and runs quality gate
/cg-approve quality         # override WARN-level quality issues
```

### Other commands

```
/cg-status   # show current session state and next action
/cg-debt     # list logged tech debt items
/cg-resume   # resume after context compaction or window restart
```

## Project structure after install

```
your-project/
├── CLAUDE.md                          # workflow instructions (the source of truth)
├── .claude/
│   ├── settings.json                  # hooks + permission denies
│   ├── hooks/
│   │   ├── pre-write.sh               # blocks file writes until plan approved
│   │   ├── pre-push.sh                # blocks git push until quality gate passed
│   │   ├── post-stop.sh               # reminds to /cg-approve implementation
│   │   └── post-compact.sh            # recovery context after context compaction
│   ├── commands/                      # slash commands (cg-*)
│   └── agents/                        # sub-agent prompts
│       ├── codebase-intelligence/     # /cg-context
│       ├── elicitation/               # Phase 1
│       ├── planning/                  # Phase 2
│       ├── plan-integrity/            # Phase 2 integrity check
│       ├── quality-gate/              # Phase 4
│       └── pr-creator/               # Phase 5
└── .ai/                               # runtime state
    ├── CODEBASE_CONTEXT.md            # commit this
    ├── tech-debt/                     # commit these
    └── sessions/                      # gitignored — ephemeral
```

## Milestone status

- [x] M0: Foundation (hooks, state machine, slash commands)
- [x] M1: Codebase Intelligence Engine
- [x] M2: Elicitation Engine (context-aware questions per task type)
- [x] M3: Plan Gate (planning agent + integrity check)
- [x] M4: Quality Gate (tests, linters, smoke, LLM review)
- [x] M5: Session Resilience (compaction recovery, /cg-resume)
- [ ] M6: SQL EXPLAIN Integration (requires MCP)
- [ ] M7: Observability Integration (requires MCP)

## Requirements

- Claude Code CLI
- Python 3 (for hook JSON parsing — standard on Linux/Mac)
- `git` (always present)
- `gh` or `glab` optional — PR creation falls back to a manual URL if neither is installed
