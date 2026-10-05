The current task's issue-tracker item, by hand. Argument: $ARGUMENTS

The workflow creates the item in Phase 0 and moves it in Phase 5 on its own (CLAUDE.md
§Issue tracker). This command is for looking at it and for overrides. Every call is
`python3 .claude/scripts/tracker.py …` and prints one JSON line.

## Dispatch

Inspect `$ARGUMENTS` (trim whitespace):

| Argument | Action |
|---|---|
| empty or `status` | `tracker.py status` — show key, title, link |
| `check` | `tracker.py check` — verify config and token; list the tracker's states and any event mapped to a state it does not have |
| `move <state>` | `tracker.py move "<state>"` — the tracker's own state name, e.g. `move "Code Review"` |
| anything else | say which arguments exist; do nothing |

Without an active session that has `.ai/sessions/{id}/tracker.json`, `status` and `move`
need an item id: ask the user for it and pass `--id`.

## Reading the result

- `{"ok": true, …}` — report `key`, `name`, `url` (and the new state for `move`).
- `{"skipped": true, "reason": …}` — no tracker for this project, or the token is
  missing. Report the reason in one line; this is not an error.
- `{"ok": false, "error": …}` — show the error.

Respond in the user's language.
