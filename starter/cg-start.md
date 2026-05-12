---
description: Bootstrap or update codegate workflow in this project
allowed-tools: Bash, Read, Write, Edit
---

# /cg-start — codegate bootstrapper

You are about to install or update **codegate** in this project. Codegate
is a structured Claude Code workflow distributed from
`https://github.com/aleksmurmur/codegate`. This is the single entry point
for all codegate lifecycle operations: install, update, adopt.

User free-text (optional): `$ARGUMENTS`

The free-text is a hint. Examples:
- `--branch dev` — clone a non-main branch.
- `stack=android-compose` — force a stack instead of detecting.
- `i edited diff-coverage.py by hand, leave it alone` — for adopt mode.

Treat the hint as advisory. If it contradicts hard checks (e.g., user
says "this is install mode" but the manifest exists), trust the checks.

---

## Step 1 — detect mode

From the project root (current directory):

```bash
MODE=
[ -f .claude/codegate-installed.yml ] && MODE=update
[ -z "$MODE" ] && { [ -f CLAUDE.md ] || [ -d .claude/agents ] || [ -d .claude/hooks ]; } && MODE=adopt
[ -z "$MODE" ] && MODE=install
echo "MODE=$MODE"
```

State machine (per design Section 4):

- `install` — clean project, first run.
- `update`  — manifest exists; refresh from upstream.
- `adopt`   — codegate-shaped layout exists, but no manifest; migrate to
              managed mode (then run an update in the same pass).

**Stage 0 status**: only `install` is implemented. If `MODE` is `update`
or `adopt`, stop and tell the user:

> This release of codegate (Stage 0) only supports first-time install.
> Update and adopt land in Stage 1+. Sorry.

Do not attempt to update or adopt manually — `cg-start.md` is the contract.

---

## Step 2 — fetch cg-core

```bash
TMPDIR=$(mktemp -d /tmp/codegate-XXXXXX) || { echo "mktemp failed"; exit 1; }
BRANCH=main
# Honor `--branch X` from $ARGUMENTS if user passed one.
git clone --depth 50 --branch "$BRANCH" \
  https://github.com/aleksmurmur/codegate "$TMPDIR" >/dev/null 2>&1 \
  || { echo "git clone failed for branch=$BRANCH"; rm -rf "$TMPDIR"; exit 1; }
echo "cg-core at: $TMPDIR ($(git -C "$TMPDIR" rev-parse --short HEAD))"
```

Save `$TMPDIR` and `$BRANCH` — every later step uses them.

If clone fails: report to user with the branch name they tried, suggest
`--branch main`, stop.

---

## Step 3 — run the runbook

```bash
RUNBOOK="$TMPDIR/core/tools/${MODE}.md"
[ -f "$RUNBOOK" ] || { echo "ERROR: runbook missing: $RUNBOOK"; rm -rf "$TMPDIR"; exit 1; }
```

Read `$RUNBOOK` and execute it step-by-step. Runbooks are the source of
truth for each mode — do not improvise. They cover stack detection,
file composition, manifest write, conflict resolution, cleanup.

When the runbook says "ask the user", ask. When it doesn't, act.

---

## Step 4 — cleanup

After the runbook returns (success or failure):

```bash
rm -rf "$TMPDIR"
```

Always. Even on failure. The clone is ephemeral by design — re-runs
re-clone, so there's nothing to preserve.

---

## Step 5 — single-line status

Tell the user one short line. Examples:

- `codegate installed for stack=kotlin-spring (49 files). Run /cg-context to seed .ai/CODEBASE_CONTEXT.md.`
- `codegate updated to ab40225. 4 files changed cleanly. 0 conflicts.`
- `codegate adopted from sha 311abfb, then updated to ab40225. 7 files changed. 1 BREAKING CHANGE — see report above.`

Do not dump the file list unless the user asks.

---

## Self-checks

Before finishing, verify the manifest exists and parses:

```bash
[ -f .claude/codegate-installed.yml ] && head -5 .claude/codegate-installed.yml
```

If the manifest is missing or empty after a successful install/update,
something silently failed in the runbook — escalate to the user.
