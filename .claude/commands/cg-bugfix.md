Start a new bug fix task session and begin Phase 1: Elicitation.

Task description: $ARGUMENTS

Follow the workflow defined in CLAUDE.md exactly:
1. Generate a session ID, create session directory, write task.md, set state to IDLE
2. Write session ID to .ai/current-session
3. Check if .ai/CODEBASE_CONTEXT.md exists; warn if not
4. If Grafana or ELK MCP servers are configured: query for relevant metrics/errors related to the bug description before generating questions. Include findings as "Observability context" in the elicitation output.
5. Run elicitation sub-agent (Task tool, .claude/agents/elicitation/prompt.md) with:
   - Task type: bugfix
   - Task description: $ARGUMENTS
   - Checklist: .claude/agents/elicitation/checklists/cg-bugfix.md
   - Context: contents of .ai/CODEBASE_CONTEXT.md if present
   - Observability context: any metrics/logs found in step 4
6. Present all elicitation questions at once to the user
7. Wait for answers, record them
8. Say: "Elicitation complete. Review the answers above, then type /cg-approve elicit to proceed to planning."
9. Stop and wait.
