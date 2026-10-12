---
name: cg-phase-3
description: Codegate Phase 3 — implementation. Use when the plan is approved (or auto-proceeded): the full-suite baseline, then the plan's commit chunks, each implemented test-first by an implementer sub-agent.
user-invocable: false
---

# Phase 3 — Implementation

**Entry**: plan approved (`/cg-approve plan`, or fast auto-proceed; the cosmetic fast-path
lands here directly). Session dir: `python3 .claude/scripts/cg_session.py dir` (`{dir}`).

1. Write `PLAN_APPROVED`, then `IMPLEMENTING` to `{dir}/state`; audit
   `[ts] Plan approved, implementation started`.
2. **ADRs for elicitation trade-offs.** In `elicitation.md`, every answer where the user picked
   one approach over another with real consequences — a library against the convention, a
   new dependency, a deliberate deviation from a pattern, a deferred piece of scope — becomes
   `{dir}/decisions/NNN-slug.md` (format in `.claude/agents/implementer/prompt.md`), before
   any code. Plain clarifications of behaviour are not ADRs.
3. **Baseline**, before any code: the full test suite — the option `test_command`
   (`.claude/scripts/cg-option.sh test_command`); without it, the stack's runner with
   coverage — vitest `npx vitest run --coverage`, jest `npx jest --coverage`, Gradle + JaCoCo
   `./gradlew test jacocoTestReport`, Maven `mvn test` — or the plain runner the project
   uses. Not sure which: ask the user once, and suggest setting `test_command`. Audit
   `[ts] baseline: <command>` — the gate runs the same command. Failures here are not this
   task's; the gate compares against them. `{dir}/test-baseline.txt`: the failing test
   names, or `CLEAN`.
4. **Chunks.** Each entry of the plan's `### Commit Plan` is a chunk; group small adjacent
   entries that touch the same files. For each chunk, in order, dispatch a sub-agent with
   `.claude/agents/implementer/prompt.md`, passing `{dir}`, the chunk's entries and the task
   type. It reads the session files itself; do not paste the plan or the conversation into
   it. This keeps the implementation's file reading and test output out of the main
   conversation, which is otherwise re-sent with every later call.
   - `STATUS: done` → check that its commits are in `git log`, go to the next chunk.
   - `STATUS: question` → ask the user (sub-agents cannot), then resume the **same**
     sub-agent with the answer (`SendMessage` to its id) — it keeps its context.
   - `STATUS: scope` → stop and put it to the user: update the plan or not. Never expand
     scope without the user.
   A one-line change may be done inline under the same rules instead of a sub-agent.
5. Audit `[ts] Implementation complete`.
6. Mode: `fast` → audit `[ts] fast-mode-auto-proceed: phase-3`, "Implementation complete.
   Auto-proceeding to quality gate." → skill `cg-phase-4`. `interactive` → "Type
   `/cg-approve implementation` to run the quality gate." Wait.

Fix rounds after the quality gate follow the same rules (skill `cg-phase-4`). Three rounds
without resolving a finding → stop and escalate to the user.

Debug mode: skill `cg-flow-feedback`, Phase 3 block.
