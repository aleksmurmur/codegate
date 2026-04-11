# {Short descriptive title}

**Severity**: HIGH | MEDIUM | LOW
**Location**: {path/to/file.kt:line — or "Multiple: see description"}
**Detected**: {YYYY-MM-DD}
**Source**: CIE | QualityGate
**Status**: OPEN

---

## Description

{What the issue is. Be specific — name the file, class, or pattern.
E.g.: "UserRepository is injected directly into OrderService, bypassing the domain boundary.
This creates a hard coupling between the user and order domains."}

## Why it matters

{The practical consequence if left unfixed.
E.g.: "Any change to UserRepository's interface now requires changes in OrderService.
Makes the order domain untestable in isolation."}

## Recommended fix

{How to address it — enough detail to start a /refactor task from this entry.
E.g.: "Introduce a UserSummaryQuery interface in the order domain. Have UserService implement it.
Inject the interface into OrderService instead of the repository.
Estimated effort: medium (affects 3 files)."}
