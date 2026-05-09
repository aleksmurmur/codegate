# codegate

A Claude Code configuration template that enforces a structured coding workflow.
Designed for teams where junior–mid developers use AI agents to write code.

Russian version: [README_ru.md](README_ru.md).

## What it does

Every task follows enforced phases before code reaches review:

1. **Elicitation** — context-aware clarifying questions. Cosmetic changes can
   short-circuit to a fast-path mini-plan (`/cg-approve quick`).
2. **Planning** — plan generated, then a mechanical integrity script verifies
   every referenced path, symbol, and migration version. An advisory pattern
   review flags deviations from HIGH-confidence conventions.
3. **Implementation** — code written against the approved plan.
4. **Quality gate** — mechanical diff-coverage check first (new production
   lines must be exercised by tests); then the LLM review across quality
   dimensions, with baseline-diffed test run and tech-debt log.
5. **PR creation** — branch, commit, PR with quality report attached.

Hooks block the agent's `Write` and `Edit` tool calls at wrong phases. Bash-based writes (redirects, `sed -i`) are not intercepted — treat the hook as a guardrail, not a sandbox.

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

Python 3 must be available for hooks and integrity/coverage scripts (standard on Linux/Mac).

## Usage

### First time in a project

```
/cg-context
```

Explores your project, produces `.ai/CODEBASE_CONTEXT.md`, logs pre-existing issues to `.ai/tech-debt/`.
Commit `CODEBASE_CONTEXT.md` so your team shares the same baseline.

### Starting a task

```
/cg-feature  add date filter to the results page
/cg-bugfix   users can't log in after password reset
/cg-refactor extract payment logic into its own service
```

Answer the elicitation questions, then follow the prompts.

### Phase approvals

```
/cg-approve quick           # accept a cosmetic fast-path proposal (skips elicitation + planning)
/cg-approve elicit          # after answering elicitation questions
/cg-approve plan            # after reviewing the generated plan
/cg-approve implementation  # commits changes, runs coverage + quality gate
/cg-approve quality         # override WARN-level quality issues
```

**Shortcut**: `/ok` is a context-aware alias. With no argument it reads
session state and runs the right `/cg-approve` automatically — five long
forms collapse into one short command throughout the flow. With an
argument (`/ok plan`) it behaves identically to the long form. Refuses
to override quality `FAIL` — the long form is required for that, by design.

### Other commands

```
/cg-status   # show current session state and next action
/cg-explain  # read-only: state + audit + checklist + diff so far
/cg-timeline # cross-session chronological view (--since 7d, --full)
/cg-debt     # list logged tech debt items
/cg-resume   # resume after context compaction or window restart
```

### Multi-persona quality gate (opt-in)

By default Phase 4 runs a single quality-gate sub-agent across all 9
dimensions. For deeper review on critical features, opt in to the
multi-persona path:

```
touch .ai/multi-persona-qg-enabled
```

Three specialized lenses run in parallel — security, architecture-and-code,
testing — each producing its own findings file. A synthesis pass then reads
all three, classifies every finding (DUPLICATE / CONTRADICTION / UNIQUE),
surfaces emergent issues from combinations (e.g. "no input validation" +
"endpoint became public" = exposed-input bug), and writes the final
QUALITY_REPORT.md in the same format as single-pass.

Cost: roughly 4× the token cost of single-pass quality gate. Use for
sensitive features (auth, payments, migrations on PII) where the extra
cost is justified — not for routine bugfixes.

Disable: `rm .ai/multi-persona-qg-enabled`.

The single-pass path remains default and is updated independently — most
tasks don't need multi-persona.

### Native Plan Mode (default on)

After Phase 2 finishes and the integrity check is CLEAN, codegate presents the
plan via Claude Code's native Plan Mode UI. The markdown presentation still
happens, and `/cg-approve plan` remains the formal approval gate — Plan Mode is
a richer preview, not a replacement.

Disable per-project by creating an empty marker file:
```
touch .ai/plan-mode-disabled
```
The flow falls back to the markdown presentation only. The same fallback is
taken automatically if `ExitPlanMode` isn't available (older Claude Code,
headless runs, non-Claude-Code harnesses).

## Optional integrations

### TDD Guard (strict TDD enforcement)

[`nizos/tdd-guard`](https://github.com/nizos/tdd-guard) is a hook-based tool
that enforces strict TDD discipline in Claude Code: blocks implementation
without a failing test, prevents over-implementation, prevents writing
multiple tests at once. It is stack-agnostic (supports 9+ test frameworks)
and orthogonal to codegate's phase machine — install per project if you
want hard TDD enforcement on top of codegate's softer "test-first chunks"
in Phase 3.

Codegate does not bundle or require it. Pointing users at it here as the
closest existing solution if you find Phase 3's red-check predictions and
multi-persona testing-lens insufficient.

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
│   ├── scripts/
│   │   ├── plan-integrity.py          # mechanical path/symbol/migration check (Phase 2)
│   │   └── diff-coverage.py           # mechanical coverage check (Phase 4)
│   └── agents/                        # sub-agent prompts
│       ├── codebase-intelligence/     # /cg-context
│       ├── elicitation/               # Phase 1 (incl. fast-path triage)
│       ├── planning/                  # Phase 2
│       ├── plan-review/               # Phase 2 advisory pattern review
│       ├── quality-gate/              # Phase 4
│       └── pr-creator/                # Phase 5
└── .ai/                               # runtime state
    ├── CODEBASE_CONTEXT.md            # commit this
    ├── tech-debt/                     # commit these
    └── sessions/                      # gitignored — ephemeral
```

## Milestone status

- [x] M0: Foundation (hooks, state machine, slash commands)
- [x] M1: Codebase Intelligence Engine
- [x] M2: Elicitation Engine (context-aware questions per task type, cosmetic fast-path)
- [x] M3: Plan Gate (planning agent, mechanical integrity script, advisory pattern review)
- [x] M4: Quality Gate (baseline-diffed tests, diff-coverage, LLM review)
- [x] M5: Session Resilience (compaction recovery, /cg-resume)
- [ ] M6: SQL EXPLAIN Integration (requires MCP)
- [ ] M7: Observability Integration (requires MCP)

## Requirements

- Claude Code CLI
- Python 3 (for hooks and integrity/coverage scripts — standard on Linux/Mac)
- `git` (always present)
- `gh` or `glab` optional — PR creation falls back to a manual URL if neither is installed
