Run the Codebase Intelligence Engine (CIE) to analyze this project and generate codebase context.

This is a standalone flow — no session needed, no task required.

Steps:
1. Run the CIE sub-agent using the Task tool with the prompt at .claude/agents/codebase-intelligence/prompt.md
2. Pass the current working directory as the project root
3. The sub-agent will explore the codebase and produce:
   - .ai/CODEBASE_CONTEXT.md (architecture, patterns, naming, SQL, tests, domain map)
   - Updates to linter configs (ktlint, ESLint, etc.) based on discovered conventions
   - .ai/tech-debt/ entries for pre-existing issues found during analysis
4. When done, report: "Codebase context generated. Review .ai/CODEBASE_CONTEXT.md and confirm it accurately describes the project before running tasks."

Note: This command is expensive (reads many files). Run once per project, then rerun only when the project architecture significantly changes.
