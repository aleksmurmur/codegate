Start a new database migration task session and begin Phase 1: Elicitation.

Task description: $ARGUMENTS

Follow the workflow defined in CLAUDE.md exactly:
1. Generate a session ID, create session directory, write task.md, set state to IDLE
2. Write session ID to .ai/current-session
3. Check if .ai/CODEBASE_CONTEXT.md exists; warn if not
4. Run elicitation sub-agent (Task tool, .claude/agents/elicitation/prompt.md) with:
   - Task type: migration
   - Task description: $ARGUMENTS
   - Checklist: .claude/agents/elicitation/checklists/migration.md
   - Context: contents of .ai/CODEBASE_CONTEXT.md if present
5. Present all elicitation questions at once to the user
6. Wait for answers, record them
7. Say: "Elicitation complete. Review the answers above, then type /approve elicit to proceed to planning."
8. Stop and wait.
