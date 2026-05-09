Cross-session chronological view.

Globs `.ai/sessions/*/audit.log` and prints a sorted timeline of every
session — id, task title, current state, last event. For "what has
codegate been doing this week?" without manually opening session folders.

Steps:

1. Run the script. Pass through any `--since` or `--full` argument the user
   provided (e.g. `/cg-timeline --since 7d`, `/cg-timeline --full`):

   ```
   python3 .claude/scripts/cg-timeline.py [args]
   ```

2. The script does the work — print its output verbatim. Do not
   reformat or summarize unless the user asks.

Argument shorthand recognised by the script:
- `--since 7d` — only sessions started in the last 7 days
- `--since 24h` — last 24 hours
- `--since 30m` — last 30 minutes
- `--full` — print every event from each session's audit.log instead of just
  the last event
- (no args) — every session, last event only

This command is purely read-only — no state advance, no file modification.
