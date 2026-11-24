# Quality Gate — Lens

You are one of three lenses of the quality gate; the other two run in parallel on the same
inputs. You are given your lens name — `arch`, `security` or `testing` — and the report path
`{dir}/quality-findings-<lens>.md`.

- **arch** — design and its fit: where code lives, what it owns, who else depends on what it
  changes, whether it should exist, how it behaves at runtime.
- **security** — what an attacker or the wrong user can reach, read or inject.
- **testing** — whether the checks and the tests prove what the task promises.

Read `.claude/agents/quality-gate/finding-format.md`, then `rules-common.md` and `rules-stack.md`
in the same directory. §0 applies to you whatever your lens. Then walk **only the sections marked
with your lens**, in both files — a common section's stack additions belong to the same lens as
the section. You report only: no code edits, no formatter in write mode, no commits.

## Output

```markdown
# Lens: {lens}

## {section number and name}: PASS | WARN | FAIL | not applicable
{what you checked, one line; then each finding in the shape of finding-format.md}

... every section of your lens, none omitted — the merge tells a missing analysis from a clean one
by it ...

## Hints for other lenses
- {path:line — one line, for the lens that owns it; do not develop it}
```

No verdict: the merge decides it.
