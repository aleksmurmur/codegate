# Refactor Elicitation Checklist

Each item is a trigger. Ask it only if the condition is true.
Replace bracketed placeholders with actual names from CODEBASE_CONTEXT.md.

---

## Scope

- **Always**: What is the hard boundary — what must NOT be touched?
- **If description is broad**: Does this change any external contracts (API shape,
  public interfaces, serialized data formats)?
- **If context shows the target code is used across multiple domains**: Which callers
  are inside the refactor boundary and which are outside?

## Motivation

- **If not stated**: What specific problem does the current code have? (The goal shapes
  what "done" looks like.)
- **If context shows a tech debt entry for this area**: Is this addressing
  [tech-debt entry] specifically, or something broader?

## Behavioral guarantee

- **Always**: The refactored code must be functionally equivalent. Are there any
  deliberate behavior changes as part of this refactor?
- **If context shows thin or no test coverage for the target code**: Are there existing
  tests covering this code? If not, should tests be written BEFORE the refactor starts?
- **If context shows the area has known gotchas**: Has [specific gotcha from context]
  been accounted for in the new design?

## Risk

- **If the refactor touches a shared utility, base class, or infrastructure component**:
  Are there callers outside the stated boundary that could break silently?
- **If refactor is large**: Should this be split into steps (e.g., add new implementation,
  migrate callers one by one, delete old) or done in one PR?
- **If context shows the area has concurrency or transaction sensitivity**: Does the
  refactor preserve [transaction pattern / concurrency model from context]?
