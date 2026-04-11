# Refactor Elicitation Checklist

## Scope
- What exactly is being refactored? (list files, classes, or packages)
- What is the hard boundary — what must NOT be touched?
- Is this purely internal (no API/interface changes) or does it change contracts?

## Motivation
- What is the goal? (readability, performance, pattern consistency, tech debt reduction)
- What specific problems does the current code have?

## Behavioral guarantee
- The refactored code must be functionally equivalent. Are there any exceptions?
- Are there existing tests that cover this code? If not, should tests be written BEFORE refactoring?
- How will you verify the refactor didn't break anything?

## Risk
- Are there callers of this code outside the refactor boundary?
- Are there any known fragile areas (tricky edge cases, side effects, timing issues)?
- Is this safe to do in one PR or should it be split into steps?
