# Agent Workflow System

This project uses a structured coding workflow (codegate). Every code change is a **task**:
one branch, one session, one PR/MR, through phases in order. Hooks block the agent's Write
and Edit calls at the wrong phase. This file is the core; each phase's steps are a skill,
loaded when the phase starts.

---

## Where the task lives

- A task's session is `.ai/sessions/{id}/`, bound to its branch (the file `branch`). The
  session of this checkout is the one whose branch is checked out here:
  `python3 .claude/scripts/cg_session.py dir` prints its directory (nothing = no task here).
  Ask the script after any branch or worktree switch; do not carry a session id in memory.
- The session is copied into the repository's shared git directory, so it survives removing
  a worktree. `/cg-tasks` lists every task: branch, state, worktree.
- Each user message comes with a `codegate:` line naming this checkout's task and state.

## Task boundary — decide on every message

1. It continues the current task → continue.
2. It concerns the current task's open PR/MR (QA bug, review remark, CI, deploy check) →
   rework, skill `cg-rework`.
3. It is other work — a new feature, an unrelated bug, a defect in an already merged task,
   an extension of the task → a **new task**, skill `cg-phase-0`. A defect after merge is a
   new bug task linked to the original; an extension is a new linked task even while the PR/MR
   is open, unless the user explicitly wants it in the same PR/MR.
4. A question, an investigation, a review, no code change → just answer; no task.

In doubt between 1–3, ask one short question. Never fold another task into this branch, and
never write code without a task on the branch.

## Phases

| Phase | Entry | Skill |
|---|---|---|
| 0 Start a task | `/cg-feature`, `/cg-bugfix`, `/cg-refactor`, or rule 3 above | `cg-phase-0` |
| 1 Session + elicitation | Phase 0 done | `cg-phase-1` |
| 2 Planning | elicitation answered | `cg-phase-2` |
| 3 Implementation | plan approved | `cg-phase-3` |
| 4 Quality gate | implementation complete | `cg-phase-4` |
| 5 PR/MR | gate passed | `cg-phase-5` |
| After the PR/MR | rule 2 above, `/cg-merged` | `cg-rework` |

On entering a phase, invoke its skill and follow it. After compaction the recovery note
names the skill to load.

States (`{dir}/state`): `IDLE → ELICITED → PLAN_APPROVED → IMPLEMENTING → QUALITY_REVIEWED →
PR_CREATED → (REWORK → PR_UPDATED)* → MERGED`; `ABANDONED` for a task closed as no longer
relevant. Log every transition to `{dir}/audit.log` with a timestamp.

## Session mode

`{dir}/mode`, set when the task starts: `fast` (default) or `interactive` (`--interactive`).
A missing file means `interactive` (sessions older than the flag).

- **fast** proceeds through phase boundaries by itself. It still stops for what only the
  user can give: business questions in elicitation, clarification and scope questions during
  implementation, gate FAILs it cannot fix in three rounds, and findings that cannot be
  overridden.
- **interactive** stops at every boundary and waits for `/cg-approve {phase}` (or `/ok`).

In fast mode, still present each artifact (plan, gate report) and say "auto-proceeding to
<next>"; audit `[ts] fast-mode-auto-proceed: <phase>`.

## Heavy work runs in sub-agents

Implementation chunks and the quality gate run in sub-agents that read the session files,
not the conversation, and return a short summary. The main conversation is re-sent with
every call, so it should hold decisions and summaries, not file dumps and test output. A
sub-agent cannot ask the user: it returns the question, you ask, then resume the same
sub-agent with the answer.

## Issue tracker

Codegate knows no tracker. `python3 .claude/scripts/tracker.py` (contract in its docstring)
passes abstract actions — create, get, event, comment, link, list — to the project's adapter
(`.claude/tracker-adapter.py`, and/or `.claude/tracker.md` describing how to do an action
with the user's own tracker tools). Every answer is one JSON line:
`{"skipped": true}` → carry on as without a tracker; `{"delegate": "agent", "how": …}` → do
the action yourself as that file says; `{"ok": false}` → show the user, never block the
workflow on it beyond the question in Phase 0.

## Hard rules

1. Never start a task on the base branch; Phase 0 creates the task branch first.
2. Never write source files in `IDLE` or `ELICITED`, nor after the PR/MR exists outside rework.
3. **Edit source files only with the Edit and Write tools** — never through the shell
   (redirects, `sed -i`, python, heredoc). Hooks and editor diagnostics see only those tools;
   a shell write is invisible to them.
4. Never expand scope beyond the approved plan without asking the user.
5. Never create a PR/MR without a completed quality gate, and never push commits made after
   it without the rework check.
6. Stage by explicit path; never `git add -A` / `git add .`.
7. Writes to `.ai/` are always allowed — that is where session data lives.
8. Asked to skip a phase: explain why it exists, then ask whether to skip anyway; if yes,
   record the skip in the audit log.
9. **Respond in the user's language** (the language of their latest message), in every
   question and status line.
10. When uncertain during implementation, ask — do not assume. Behaviour, API shape, data
    model and user-visible output are the user's call; small technical choices go to an ADR.

## Commands

- `/cg-context` — explore the project, write `.ai/CODEBASE_CONTEXT.md`, seed tech debt. No task.
- `/cg-feature`, `/cg-bugfix`, `/cg-refactor [--interactive] <task or tracker key>` — start a task.
- `/cg-approve {quick|elicit|plan|implementation|quality}`, `/ok` — approvals (interactive mode;
  `/cg-approve quality` also overrides a FAIL in either mode).
- `/cg-status`, `/cg-explain` — the current task; `/cg-tasks` — all tasks; `/cg-resume` — pick
  up the task of this checkout after `/clear` or in a new window.
- `/cg-merged` — is this task's PR/MR merged; closes the task when it is.
- `/cg-next` — tracker items assigned to you in this project.
- `/cg-tracker`, `/cg-debt`, `/cg-timeline`, `/cg-debug [on|off]` — tracker item by hand, tech
  debt list, timeline across sessions, flow-feedback mode (skill `cg-flow-feedback`).
