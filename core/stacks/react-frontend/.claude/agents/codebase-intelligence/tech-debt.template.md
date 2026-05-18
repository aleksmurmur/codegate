# {Short descriptive title}

**Severity**: HIGH | MEDIUM | LOW
**Location**: {src/path/file.tsx:line — or "Multiple: see description"}
**Detected**: {YYYY-MM-DD}
**Source**: CIE | QualityGate
**Status**: OPEN

---

## Description

{What the issue is. Be specific — name the file, component, hook, or pattern.
E.g.: "useUserProfile hook re-fetches on every render because its dependency
array contains a freshly-allocated object literal. Visible as duplicate
network requests on the profile screen."}

## Why it matters

{The practical consequence if left unfixed.
E.g.: "Doubles API load on the profile screen, leaks server-side rate-limit
headroom, and produces a visible flicker during the second fetch resolving."}

## Recommended fix

{How to address it — enough detail to start a /refactor task from this entry.
E.g.: "Memoize the dependency with useMemo, or move the literal outside the
component. Estimated effort: small (1 file). Add a regression test that
counts mock fetch calls."}
