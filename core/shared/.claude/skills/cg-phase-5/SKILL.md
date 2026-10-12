---
name: cg-phase-5
description: Codegate Phase 5 — PR/MR creation. Use when the quality gate and the independent review concluded: commit logged tech debt, create the PR/MR, linked tasks for consumers, tracker event.
user-invocable: false
---

# Phase 5 — PR/MR

**Entry**: the gate concluded (PASS, WARN accepted, FAIL overridden) and the independent
review concluded (Phase 4 §5). Session dir:
`python3 .claude/scripts/cg_session.py dir` (`{dir}`).

1. **Tech debt this task logged.** The gate writes `.ai/tech-debt/*.md` after the last
   commit; without this step the notes never leave the machine.
   `git status --porcelain --untracked-files=all .ai/tech-debt` → stage those paths explicitly,
   `git commit -m "docs: tech debt logged by <ticket or task>"`. Ignored by git in this
   project → skip and say so under "Tech Debt Logged".
2. **PR/MR**: sub-agent `.claude/agents/pr-creator/prompt.md` with `{dir}`. It targets
   `{dir}/target-branch`, never the hosting default. Its last line is `PR_URL: <url>` or
   `PR_URL: none`.
3. State `PR_CREATED`; audit `[ts] PR created: {url}` (or `[ts] Branch pushed, PR/MR to be
   created by hand`). Write the url (when real) to `{dir}/pr-url`.
4. **Tracker**, only with a real `PR_URL` and `{dir}/tracker.json`:
   `python3 .claude/scripts/tracker.py event pr_created` and
   `python3 .claude/scripts/tracker.py comment --body "PR/MR: <url>"`; audit the outcome.
   `{"delegate": "agent", …}` → do it yourself as the named file says. A tracker failure
   never fails the PR.
5. **Consumers.** When PLAN.md has `## Consumers` (elicitation found other projects that need
   work because of this change): for each, draft a task in markdown with the sections
   `## Context` (one paragraph), `## Contract` (the interface they depend on — e.g. endpoints,
   fields, types, errors, events — as built, from the diff, not as planned), `## Semantics` (edge cases, what each value means),
   `## Rollout order` (relative to this PR/MR), `## Acceptance`, `## Links` (the PR/MR, this task).
   Consuming repositories are told to read exactly these sections (`/cg-tracker snippet`). Show the drafts together and ask once: "Create these tasks?" (the user may edit
   or drop any). Then for each confirmed draft, written to `{dir}/consumer-<alias>.md`:
   `python3 .claude/scripts/tracker.py create --project <alias> --type feature --title "<title>" --body-file {dir}/consumer-<alias>.md --relates <KEY>:relates --link <PR url>`.
   Record the created keys in the audit log and add a `## Consumers` list to the PR/MR
   description where the host CLI allows (`gh pr edit`, `glab mr update`); otherwise give the
   user the list. No tracker → leave the drafts in `{dir}` and say where they are.
6. Tell the user in one line what is next: QA or review findings on this PR/MR are fixed on this
   branch (rework, skill `cg-rework`); `/cg-merged` checks whether it is merged.

Debug mode: skill `cg-flow-feedback`, Phase 5 block and the session summary.
