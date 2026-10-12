The current task's issue-tracker item, by hand. Argument: $ARGUMENTS

The workflow creates the item in Phase 0, comments on it and moves it on its own (core
CLAUDE.md, §Issue tracker). This command is for looking at it and for overrides. Every call
is `python3 .claude/scripts/tracker.py …` and prints one JSON line.

## Dispatch

Inspect `$ARGUMENTS` (trim whitespace):

| Argument | Action |
|---|---|
| empty or `status` | `tracker.py status` — key, title, link |
| `get <KEY>` | `tracker.py get <KEY>` — an existing item's title, state and description |
| `check` | `tracker.py check` and `tracker.py capabilities` — config, token, states, what the adapter can do |
| `move <state>` | `tracker.py move "<state>"` — the tracker's own state name, e.g. `move "Code Review"` |
| `comment <text>` | `tracker.py comment --body "<text>"` |
| `link <KEY> <type>` | `tracker.py link --relates <KEY>:<type>` — type: relates, blocks, blocked_by, caused_by |
| `snippet` | print the paragraph below for a consuming repository's `AGENTS.md` / `CLAUDE.md` |
| anything else | say which arguments exist; do nothing |

Without a task on this branch that has `tracker.json`, `status`, `move`, `comment` and `link`
need an item id: ask the user for it and pass `--id`.

## Reading the result

- `{"ok": true, …}` — report `key`, `name`, `url` (and the new state for `move`).
- `{"skipped": true, "reason": …}` — no tracker, missing token, or the adapter cannot do
  this. One line; not an error.
- `{"delegate": "agent", "how": …, "action": …}` — do the action yourself with the user's
  tracker tools, as that file describes; report the result the same way.
- `{"ok": false, "error": …}` — show the error.

## Snippet for consuming repositories

Repositories that receive tasks from this one (front end, mobile) may not run codegate. Give
the user this paragraph to put in their `AGENTS.md` or `CLAUDE.md`, with the tracker named:

> Tasks for this repository may come from the backend as tracker items linked to a backend
> task. Given an item key, read it with your tracker tool: its "Contract" section is the API
> as built (endpoints, fields, types, errors), "Rollout order" says what must be deployed
> first, and the linked backend item has the merge request. Ask before deviating from the
> contract; report contract problems as a comment on the item.

Respond in the user's language.
