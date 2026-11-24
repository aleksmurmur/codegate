# codegate

A Claude Code configuration template that enforces a structured coding workflow.
Designed for teams where junior–mid developers use AI agents to write code.

Russian version: [README_ru.md](README_ru.md).

## What it does

Every task follows enforced phases before code reaches review:

0. **Start** — a task is a branch: its own session, bound to that branch. When the folder
   holds unfinished work, the new task goes to its own worktree.
1. **Elicitation** — the agent first maps who reads and writes the data the task touches,
   then asks in rounds of at most four questions, each with a recommendation — architecture
   (how the change fits the system, options, a simpler or broader alternative) and business
   never in one message — until nothing is open; a task that is really several is offered as a split. It ends with a summary of what is settled and what it decided itself.
   A **small task** skips all of this: clear what to build (a question about a detail is
   fine), nothing expensive to reverse
   (no new table, column, API field or endpoint), one place, no area the project excluded
   (option `short_path_excluded`; the full rules: `.claude/agents/elicitation/short-path.md`).
   A refactor qualifies on the same terms. The agent says so in one line with 1–3 acceptance
   criteria; a word from the user confirms it, and the task goes test-first straight to the
   gate, the review and the PR/MR. If it turns out bigger, it goes back to elicitation.
   Before the user sees any architecture question, the agent writes a design draft
   (`design.md`): the shape, each decision with its options, and the growth it touches.
   Growth is weighed by cost, not by guessing odds: the simpler option when it can grow
   cheaply later; simpler with the door kept open when locking out is avoidable for little;
   a question to the user only for a costly bet on growth with a source. A design
   critic with no part in the conversation reads the draft and the code: prior art, a
   simpler shape, over- or under-built extensibility, risks, decisions left open. The agent
   adopts, declines or turns each finding into a question, so the options the user picks
   from have already been challenged.
2. **Planning** — the agreed design written down as files, tests and commits; the planner
   makes no design decision of its own and brings back any the design left open. A
   mechanical integrity script then verifies every referenced path, symbol, and migration
   version, and warns when a file the plan will create already names an existing symbol.
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
   that consume the change (another service, an app), after the user confirms the drafts.
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

Install adds to `.gitignore` (session data is per machine; codebase context is kept, tech debt
by the option `tech_debt_in_git`):

```
.ai/sessions/
.ai/current-session
.claude/worktrees/
```

Sessions are also copied into the repository's git directory (`.git/codegate/sessions/`),
shared by all worktrees, so removing a worktree does not lose its task.

Python 3 is required: the hooks parse every call with it. Without it, every Write/Edit and
every push or PR/MR creation is blocked (standard on Linux/Mac; on Windows install it).

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
/cg-refactor extract the export logic into its own module
```

Answer the elicitation questions; the phases then proceed by themselves.

### When it stops

There is one mode: no approval is typed between phases. The workflow stops only for what
the user alone can give — an elicitation round, a question about behaviour or scope during
implementation, a gate FAIL it could not fix in three rounds, a finding that cannot be
overridden. It still shows each artifact (the plan, the gate report) on the way.

```
/cg-approve quality   # accept the FAIL items the gate could not get fixed
/ok                   # "yes, go on": accept a round's recommendations; never overrides a FAIL
```

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

### Quality gate: one list, one or three agents

Phase 4 first runs the mechanical checks as commands: the full test suite, diff coverage,
the assertion check, the linters the project has configured (check mode only), and the
project's own checks from the option `gate_checks` (a migration linter, architecture tests).
Linters that take files see only the files the task changed; the others, and the project's
checks (given `CG_BASE` and `CG_CHANGED_FILES` to scope themselves), may see the whole
project, and the gate counts only failures the change caused. A check runs to its end: there
is no time limit to skip it by. Code style — naming, function size, comments — is not a gate
rule: the linters and the project's own rules carry it.
Then the gate judges the result against one list of rules: what is common to every stack in
`.claude/agents/quality-gate/rules-common.md`, the stack's additions in `rules-stack.md`, the
severities and the finding shape — shared with the independent review — in
`finding-format.md`. The gate reports; a fix sub-agent fixes and commits.

The option `gate_mode` picks how the list is walked: `single` (default) — one agent walks all
of it; `lenses` — three agents (architecture, security, testing) each walk the sections marked
with their lens, and a merge step folds duplicates, one-cause-many-places findings and
combinations into the same report. Three agents cost more tokens; use them for sensitive
features (access, payments, personal data). Switch with `/cg-start gate_mode=lenses`.

### Native Plan Mode (default on)

After Phase 2 finishes and the integrity check is CLEAN, codegate presents the
plan via Claude Code's native Plan Mode UI. The markdown presentation still
happens — Plan Mode is a richer preview, not a replacement.

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
project whose suite needs a wrapper script sets it there. A team that opens PRs/MRs its own way
(required flags, push options) gives that command as `pr_command`. `/cg-tracker` for the current item by
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
the gate's test rules insufficient.

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
│   │   ├── cg_cmd.py                  # what a Bash call runs: pushes and PR/MR creations, for the hooks
│   │   ├── tracker.py                 # tracker bridge (actions → project adapter)
│   │   ├── plan-integrity.py          # mechanical path/symbol/migration check (Phase 2)
│   │   ├── test-assertions.py         # mechanical no-op-assertion check (Phase 4)
│   │   ├── diff-coverage.py           # mechanical coverage check (Phase 4)
│   │   ├── gate-checks.sh             # linters and project checks (Phase 4)
│   │   └── linters.sh                 # which linters the project has (stack-specific)
│   └── agents/                        # sub-agent prompts
│                                      # (cg-core's own test suites live in
│                                      #  core/tests/ and are NOT installed)
│       ├── codebase-intelligence/     # /cg-context
│       ├── elicitation/               # Phase 1 (incl. the small-task check)
│       ├── planning/                  # Phase 2
│       ├── implementer/               # Phase 3, one plan chunk test-first
│       ├── design-critic/             # Phase 1, fresh read of the design draft
│       ├── quality-gate/              # Phase 4: gate, lens, rules, finding format
│       ├── independent-review/        # Phase 4, last step: sees only task and code
│       └── pr-creator/                # Phase 5
└── .ai/                               # runtime state
    ├── CODEBASE_CONTEXT.md            # commit this
    ├── tech-debt/                     # in git unless tech_debt_in_git = no
    └── sessions/                      # gitignored — ephemeral
```

## Milestone status

- [x] M0: Foundation (hooks, state machine, slash commands)
- [x] M1: Codebase Intelligence Engine
- [x] M2: Elicitation Engine (context-aware questions per task type, short path for small tasks)
- [x] M3: Plan Gate (planning agent, mechanical integrity script; the design critique moved to Phase 1)
- [x] M4: Quality Gate (baseline-diffed tests, diff-coverage, assertion check, LLM review)
- [x] M5: Session Resilience (compaction recovery, /cg-resume)
- [ ] M6: SQL EXPLAIN Integration (requires MCP)
- [ ] M7: Observability Integration (requires MCP)

## Requirements

- Claude Code CLI
- Python 3 — required: the hooks block writes and pushes without it (standard on Linux/Mac)
- `git` (always present)
- `gh` or `glab` optional — PR creation falls back to a manual URL if neither is installed
