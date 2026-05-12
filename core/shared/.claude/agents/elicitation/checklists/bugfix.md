# Bug Fix Elicitation Checklist

Each item is a trigger. Ask it only if the condition is true.
Replace bracketed placeholders with actual names from CODEBASE_CONTEXT.md.

---

## Reproduction

- **Always**: How do you reproduce it? Steps, inputs, environment.
- **If description doesn't say**: Is this consistent or intermittent?
- **If description doesn't say**: When did it start — after a specific deploy, always existed,
  or after a data change?

## Expected vs actual

- **If not clear from description**: What should happen vs what actually happens?
- **If context shows a logging/observability setup**: Are there any relevant log lines, stack
  traces, or [metrics/traces from context] that point to the cause?

## Root cause

- **If description doesn't mention a suspected location**: Is there a hypothesis about where
  in the code this originates? Has anyone looked at [logging system from context] yet?
- **If context shows a known fragile area (from Gotchas)**: Could this be related to
  [specific gotcha]?

## Scope of fix

- **Always**: Should the fix be minimal (patch exactly what's broken) or is a broader fix
  appropriate?
- **If context shows the same pattern used in multiple places**: Are there other locations
  in the codebase with the same pattern that might have the same bug?
- **If bug involves data**: Does fixing this require a data migration or backfill for
  already-corrupted rows?

## Side-effects of the fix

- **If the fix touches a shared utility, base class, or cross-domain component**: Which other
  domains or features could be affected by this change?
- **If context shows a caching layer near the bug**: Does the fix require cache invalidation
  or a cache flush?

## Security

Trigger when the bug or affected code involves any of:
auth, login, password, token, secret, payment, API key, file upload, user input,
PII (email, phone, SSN, address), file path from user, outbound HTTP, raw SQL.

- **If trigger fired**: Could this bug have leaked or mishandled sensitive data while it
  was unfixed? Does the fix need to be paired with log redaction or data cleanup?
- **If trigger fired**: After the fix, what must remain true — what input must be
  validated, what data must not appear in logs, who must / must-not access the surface?
