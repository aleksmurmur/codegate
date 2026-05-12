List all logged tech debt items.

Steps:
1. Check if .ai/tech-debt/ directory exists and has any .md files
2. If empty or missing: say "No tech debt logged. Good shape."
3. If items exist, for each file in .ai/tech-debt/*.md:
   - Read the file
   - Extract: title (first heading), severity, location, brief description
4. Present as a table:
   | File | Location | Severity | Summary |
   |------|----------|----------|---------|
   | ...  | ...      | ...      | ...     |
5. At the end, show total count and a note: "To address an item, run /cg-refactor with the relevant file as context."
