Toggle or query the project-level **debug mode** marker file. Argument: $ARGUMENTS

Debug mode collects observations about the flow itself (what worked, what
was friction, what to improve, what's missing) into a per-session
`flow-feedback.md`. See CLAUDE.md §Debug mode for the full semantics and
the format of recorded blocks.

## Dispatch

Inspect `$ARGUMENTS` (trim whitespace):

| Argument | Action |
|---|---|
| (empty) | Report status (see below) |
| `on` | `mkdir -p .ai && touch .ai/cg-debug-mode`. Say: "Debug mode: ON. The next session will record flow-feedback.md." |
| `off` | `rm -f .ai/cg-debug-mode`. Say: "Debug mode: OFF. The next session will NOT record flow-feedback.md. Existing per-session feedback files are not deleted." |
| anything else | Say: "Unknown argument `<arg>`. Use `/cg-debug on`, `/cg-debug off`, or `/cg-debug` (status)." Stop. |

## Status (no-argument form)

```bash
if [ -f .ai/cg-debug-mode ]; then
  echo "Debug mode: ON"
else
  echo "Debug mode: OFF"
fi
```

If `.ai/current-session` exists, also report whether the current
session's `.ai/sessions/{id}/flow-feedback.md` exists and how many
phase blocks it contains (`grep -c '^## Phase'`). This tells the user
both the global toggle state and what the current session has captured
so far.

## Notes

- The marker is **project-level** and persists across sessions. Turning
  it on once means every subsequent session captures feedback until
  turned off.
- The marker takes effect at the next phase boundary. Toggling it
  mid-session works (the next boundary will read the file fresh) but
  produces gappy feedback files.
- The marker is independent of `mode` (fast / interactive). Both modes
  capture feedback when the marker is present.
- Per-session `flow-feedback.md` files are never auto-deleted. Inspect
  them with `cat .ai/sessions/{id}/flow-feedback.md` or aggregate across
  sessions with `find .ai/sessions -name flow-feedback.md -exec cat {} +`.
