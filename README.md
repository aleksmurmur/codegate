# Agent Workflow System

A Claude Code configuration template that enforces a structured coding workflow.
Designed for teams where non-senior developers use AI agents to write code.

## What it does

Every task follows enforced phases before code reaches review:

1. **Elicitation** — context-aware clarifying questions before any planning
2. **Plan approval** — human reviews and approves a plan before any files are written
3. **Implementation** — code written against the approved plan
4. **Quality gate** — automated review against codebase conventions + linters
5. **PR creation** — branch, commits, PR with quality report attached

Hooks physically block file writes at wrong phases — the agent cannot bypass them.

## Install

Copy the following into your project root:

```
CLAUDE.md
.claude/
```

Then add `.ai/` to your `.gitignore`:

```
echo ".ai/" >> .gitignore
```

That's it. No extra dependencies for phases 1–4. Python 3 must be available for the hooks (used for JSON parsing — standard on most systems).

## Usage

### First time in a project

```
/context
```

Runs the Codebase Intelligence Engine: explores your project, produces `.ai/CODEBASE_CONTEXT.md`,
updates linter configs, logs any pre-existing issues to `.ai/tech-debt/`.

Review `CODEBASE_CONTEXT.md` and confirm it accurately describes your project.

### Starting a task

```
/feature add date filter to the results page
/bugfix users can't log in after password reset
/migration add index to orders table
/refactor extract payment logic into its own service
```

The workflow begins automatically. Answer the elicitation questions, then follow the prompts.

### Approving phases

```
/approve elicit     # after answering elicitation questions
/approve plan       # after reviewing the generated plan
/approve quality    # to override WARN-level quality issues
```

### Other commands

```
/status     # show current session state
/debt       # list logged tech debt items
```

## Project structure after install

```
your-project/
├── CLAUDE.md                    # workflow instructions (don't delete)
├── .claude/
│   ├── settings.json            # hooks + permission denies
│   ├── hooks/
│   │   ├── pre-write.sh         # blocks file writes until plan approved
│   │   └── post-stop.sh         # warns if quality gate not run
│   ├── commands/                # slash commands
│   └── agents/                  # sub-agent prompts
└── .ai/                         # runtime state (gitignored)
    ├── CODEBASE_CONTEXT.md
    ├── tech-debt/
    └── sessions/
```

## Milestone status

- [x] M0: Foundation (hooks, state machine, slash commands)
- [ ] M1: Codebase Intelligence Engine
- [ ] M2: Elicitation Engine (context-aware questions)
- [ ] M3: Plan Gate
- [ ] M4: Quality Gate
- [ ] M5: SQL EXPLAIN Integration
- [ ] M6: Observability Integration
- [ ] M7: Open Source Release

Sub-agent prompts in `.claude/agents/` are functional stubs until their milestones are complete.
The enforcement layer (hooks, state machine) is fully functional now.

## Requirements

- Claude Code CLI
- Python 3 (for hook JSON parsing — standard on Linux/Mac)
- `gh` CLI (for PR creation in Phase 5)
- Optional: `jq` (hooks fall back to Python if not available)
