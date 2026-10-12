# codegate

A Claude Code configuration template that enforces a structured coding workflow.
Designed for teams where junior–mid developers use AI agents to write code.

Russian version: [README_ru.md](README_ru.md).

## What it does

Every task follows enforced phases before code reaches review:

0. **Start** — a task is a branch: its own session, bound to that branch. When the folder
   holds unfinished work, the new task goes to its own worktree.
1. **Elicitation** — the agent first maps who reads and writes the data the task touches,
   then sends one message: how the change fits the system (options, its choice, a simpler
   or broader alternative), at most four business questions with a recommendation each, and
   the small things it decided itself. Cosmetic changes can short-circuit to a fast-path
   mini-plan (`/cg-approve quick`).
2. **Planning** — plan generated, then a mechanical integrity script verifies
   every referenced path, symbol, and migration version, and warns when a file
   the plan will create already names an existing symbol. An advisory pattern
   review then reads the codebase for prior art — something that already does
   what the plan proposes to build — and flags deviations from HIGH-confidence
   conventions.
3. **Implementation** — code written against the approved plan, chunk by chunk, test first,
   each chunk in a sub-agent that works from the session files.
4. **Quality gate** — two mechanical checks first: diff coverage (new
   production lines must be exercised by tests) and test assertions (tests the
   diff touched must assert something that could fail — coverage proves a line
   ran, not that anything would notice it being wrong). Then the LLM review
   across quality dimensions, reading whole files rather than only the diff,
   with baseline-diffed test run and tech-debt log. Last, an independent review: a
   sub-agent that sees only the task and the code, not the plan or the author's reasoning.
5. **PR creation** — PR/MR with the quality report; linked tracker tasks for the projects
   that consume the change (front end, mobile), after the user confirms the drafts.
6. **After the PR/MR** — QA findings, review remarks and CI fixes are *rework*: same branch,
   a check of only the new commits before they are pushed. A defect found after the merge, or
   an extension, is a new task linked to the original.

`CLAUDE.md` holds only the core (~6k characters); each phase's steps are a skill
(`.claude/skills/cg-phase-N`) loaded when the phase starts, so they are not re-sent with every
model call and every sub-agent.

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
.claude/worktrees/
```

Sessions are also copied into the repository's git directory (`.git/codegate/sessions/`),
shared by all worktrees, so removing a worktree does not lose its task.

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
/cg-status   # this branch's task: state and next action
/cg-tasks    # every task in the repository: branch, state, worktree
/cg-merged  # is this task's PR/MR merged? closes the task when it is
/cg-next     # tracker items assigned to you, and which are already started
/cg-explain  # read-only: state + audit + checklist + diff so far
/cg-timeline # cross-session chronological view (--since 7d, --full)
/cg-debt     # list logged tech debt items
/cg-resume   # pick up this branch's task after /clear, compaction or a new window
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

### Issue tracker

Codegate knows no tracker. It asks for abstract actions — create (also for another project,
with a relation and a link), get, event (`started`, `pr_created`, `merged`), comment, link,
list mine — through `.claude/scripts/tracker.py` (contract in its docstring). The project
answers them with its own adapter, in one or both forms: `.claude/tracker-adapter.py`, a
script; and `.claude/tracker.md`, instructions for doing an action with the tools the
user's AI already has for that tracker (an MCP server, a CLI). An action the script cannot
do is handed to the agent with those instructions, or skipped. Config and credentials stay
with the project. `/cg-start` asks whether to use a tracker (`tracker`: `none` or `adapter`)
and which projects consume this one (`consumers`). It also asks how the full test suite
runs (`test_command`): the workflow runs it before any code and in the quality gate; a
project whose suite needs a wrapper script sets it there. `/cg-tracker` for the current item by
hand, `/cg-next` for what is assigned to you.

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
│   │   ├── pre-agent.sh               # no elicitation/planning without a task on the branch
│   │   ├── task-context.sh            # each message carries this branch's task and state
│   │   ├── post-stop.sh               # copies sessions to the shared store
│   │   └── post-compact.sh            # where the task stands, on session start and compaction
│   ├── skills/                        # cg-phase-0…5, cg-rework, cg-flow-feedback
│   ├── commands/                      # slash commands (cg-*)
│   ├── scripts/
│   │   ├── cg_session.py              # which task belongs to this checkout; shared store
│   │   ├── tracker.py                 # tracker bridge (actions → project adapter)
│   │   ├── plan-integrity.py          # mechanical path/symbol/migration check (Phase 2)
│   │   ├── test-assertions.py         # mechanical no-op-assertion check (Phase 4)
│   │   └── diff-coverage.py           # mechanical coverage check (Phase 4)
│   └── agents/                        # sub-agent prompts
│                                      # (cg-core's own test suites live in
│                                      #  core/tests/ and are NOT installed)
│       ├── codebase-intelligence/     # /cg-context
│       ├── elicitation/               # Phase 1 (incl. fast-path triage)
│       ├── planning/                  # Phase 2
│       ├── implementer/               # Phase 3, one plan chunk test-first
│       ├── plan-review/               # Phase 2 advisory prior-art / pattern review
│       ├── quality-gate/              # Phase 4
│       ├── independent-review/        # Phase 4, last step: sees only task and code
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
- [x] M4: Quality Gate (baseline-diffed tests, diff-coverage, assertion check, LLM review)
- [x] M5: Session Resilience (compaction recovery, /cg-resume)
- [ ] M6: SQL EXPLAIN Integration (requires MCP)
- [ ] M7: Observability Integration (requires MCP)

## Requirements

- Claude Code CLI
- Python 3 (for hooks and integrity/coverage scripts — standard on Linux/Mac)
- `git` (always present)
- `gh` or `glab` optional — PR creation falls back to a manual URL if neither is installed
