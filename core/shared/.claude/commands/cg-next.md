---
description: What to work on — tracker items assigned to you in this project, with any task already started for them
---

Suggest what to do next. Read-only until the user picks something.

1. `python3 .claude/scripts/tracker.py list --mine` (add `--project <alias>` when `$ARGUMENTS`
   names one).
   - `{"ok": true, "items": [...]}` → go on.
   - `{"delegate": "agent", "how": …}` → get the list yourself with the user's tracker tools,
     as that file describes.
   - `{"skipped": true}` / `{"ok": false}` → say the tracker cannot list assigned items here and
     why, and stop.
2. `python3 .claude/scripts/cg_session.py list --json` — tasks already started. Match them to
   items by ticket.
3. Show at most 10 items: key, title, tracker state, and the local task if one exists (branch,
   state). Put first what is already in progress here, then items blocked on nothing, newest
   first.
4. Offer: "Start <KEY>?" — on yes, `/cg-feature <KEY>` (or `/cg-bugfix` for a bug); an item
   with a local task continues in its worktree (`EnterWorktree`, then `/cg-resume`). Without `EnterWorktree` do not `cd` there — sub-agents would stay in this folder: tell the user to open a conversation in that directory and run `/cg-resume` there.

Respond in the user's language.
