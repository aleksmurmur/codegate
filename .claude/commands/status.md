Show the current session status.

Steps:
1. Read .ai/current-session
2. If file does not exist or is empty: say "No active session. Start one with /feature, /bugfix, /migration, or /refactor."
3. Otherwise, read:
   - .ai/sessions/{id}/task.md (task description)
   - .ai/sessions/{id}/state (current phase)
   - .ai/sessions/{id}/audit.log (recent activity)
4. Report clearly:
   - Session ID
   - Task: [description from task.md]
   - Current state: [state]
   - What happened: [last 3 lines of audit.log]
   - What to do next: [based on current state]

State → Next action mapping:
- IDLE → "Answer the elicitation questions, then type /approve elicit"
- ELICITED → "Review the plan in .ai/sessions/{id}/PLAN.md, then type /approve plan"
- PLAN_APPROVED / IMPLEMENTING → "Implementation is in progress"
- QUALITY_REVIEWED → "Review QUALITY_REPORT.md, then PR will be created"
- PR_CREATED → "Task complete. PR has been created."
