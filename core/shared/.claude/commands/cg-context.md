Run the Codebase Intelligence Engine (CIE) to analyze this project and generate codebase context.

This is a standalone flow — no session needed, no task required.

Steps:
1. Run the CIE sub-agent using the Task tool with the prompt at .claude/agents/codebase-intelligence/prompt.md
2. Pass the current working directory as the project root
3. The sub-agent will explore the codebase and produce:
   - .ai/CODEBASE_CONTEXT.md (architecture, patterns, naming, SQL, tests, domain map)
   - Updates to linter configs (ktlint, ESLint, etc.) based on discovered conventions
   - .ai/tech-debt/ entries for pre-existing issues found during analysis
4. **Commit the CIE output** so it doesn't bleed into the next session's
   `git status` (a `/cg-feature` started against an unrelated dirty tree
   confuses the Phase 4 catchall commit step):
   - `git add .ai/CODEBASE_CONTEXT.md .ai/tech-debt/`
   - Also stage any linter config files the CIE modified (`.editorconfig`,
     `eslint.config.*`, `.prettierrc*`, `detekt.yml`, etc.) — only the
     ones with CIE-added markers (look for the `Added by codegate CIE on`
     comment).
   - `git commit -m "chore: codegate CIE — codebase context + tech debt"`.
   - If `git status` is clean before the CIE run produced no changes
     (rare — usually means CIE re-ran on an unchanged tree), skip the
     commit step and report "no changes from CIE".
5. When done, report: "Codebase context generated and committed. Review .ai/CODEBASE_CONTEXT.md and confirm it accurately describes the project before running tasks."

Note: This command is expensive (reads many files). Run once per project, then rerun only when the project architecture significantly changes.
