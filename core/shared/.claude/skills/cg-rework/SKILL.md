---
name: cg-rework
description: Codegate after the PR/MR exists — a fix to the open MR (QA bug, review remark, CI failure, deploy check), the delta check before pushing it, and closing the task when the MR is merged. Use when a message concerns the current task's PR/MR.
user-invocable: false
---

# After the PR/MR: rework and merge

The session lives on after its PR/MR: deploys get checked, QA and clients find bugs, CI
breaks, scope grows. Codegate keeps those changes checked instead of pushing them blind.
States: `PR_CREATED → REWORK → PR_UPDATED → (REWORK → PR_UPDATED)* → MERGED`.
Session dir: `python3 .claude/scripts/cg_session.py dir` (`{dir}`).

## Is it rework at all?

| The message | What it is |
|---|---|
| A defect or remark about this task's MR, MR **not merged** (QA, review, CI, deploy check) | **rework** — same branch, same MR, no new task |
| A defect in this task, MR **merged** | a new bug task linked to this one: skill `cg-phase-0`, `--relates <KEY>:caused_by` |
| An extension — more than the task asked for — merged or not | a new task linked to this one (`--relates <KEY>:relates`). Into the same MR only when the user says so explicitly; then it is rework with reason `scope` |
| Unrelated work | a new task: skill `cg-phase-0` |

Not sure whether the MR is merged: `/cg-mr` (below) first.

## Rework

1. Write `REWORK` to `{dir}/state`; audit `[ts] Rework: <qa|review|ci|self|scope> — <one line>`.
   Tracker (when `tracker.json` exists): `python3 .claude/scripts/tracker.py comment --body "Rework: <reason> — <one line>"`.
2. Reason `scope`: a short elicitation first — only the new questions, same format — and an
   addendum to PLAN.md (`## Addendum N`), then implement.
3. Fix test-first, as in Phase 3: a test that reproduces the report, then the fix; commits
   staged by explicit path; audit lines per commit.
4. **Delta check** — everything after `{dir}/checked-sha` (the last checked commit):
   - the tests of the classes the delta touches, plus the new ones;
   - the quality-gate sub-agent (`.claude/agents/quality-gate/prompt.md`) on the delta only:
     `git diff <checked-sha>..HEAD`, the files it touches, and the sibling paths of what
     changed. Reason `scope` → the full Phase 4 instead (skill `cg-phase-4`);
   - diff coverage on the delta when production code changed
     (`diff-coverage.py --base <checked-sha>`).
   Report in `{dir}/rework-N.md`. FAIL → fix and re-check the new commits, up to 3 rounds.
5. Passed: write `git rev-parse HEAD` to `{dir}/checked-sha`, state `PR_UPDATED`, audit
   `[ts] Rework checked: <sha>`. Push (the push gate compares the pushed HEAD with
   `checked-sha`; commits that touch only `.ai/` do not count).
6. A merge of the target branch into this one is not rework; only conflict resolutions
   that change code are, and they get the delta check like any fix.

## Merged — `/cg-mr`

`git fetch origin`, then `python3 .claude/scripts/cg_session.py facts`:
- `merged: true` → state `MERGED`, audit `[ts] Merged into <target>`,
  `python3 .claude/scripts/tracker.py event merged`. The task is closed; the next one starts
  from a fresh base branch (skill `cg-phase-0`).
- not merged → report the MR as open (url from `{dir}/pr-url`), commits since `checked-sha`
  if any, and the state.

Merge detection compares commits, so a squash merge does not show as merged: then ask the
user, or check the MR on the host.
