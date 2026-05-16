# Feature Elicitation Checklist

Each item is a trigger. Ask it only if the condition is true.
Replace bracketed placeholders with actual names from CODEBASE_CONTEXT.md.

---

## Happy path and errors

- **Always**: What is the exact expected behavior on the happy path?
- **If description is vague about failure cases**: What should happen when [specific
  not-found or invalid input case]? Return an error or silently do nothing?
- **If context shows typed domain exceptions**: Should errors use the existing exception
  pattern (e.g., throw `[ExceptionType]`) or is a new exception type needed?

## Scope boundary

- **If description could naturally extend further**: Should the implementation stop at
  [inferred boundary], or does it also include [adjacent thing]?
- **If context shows multiple domains are affected**: Does this change any behavior in
  [adjacent domain]? Should it?

## Persistence

- **If the feature clearly touches the DB**: Is this additive (new column/table) or does
  it modify existing rows?
- **If context shows a migration tool (Flyway, Liquibase, etc.)**: Which migration
  identifier should this be (Flyway version, Liquibase `(id, author)`, etc.)? Are there
  pending migrations in other branches?
- **If feature introduces new queries on large tables**: Will the new query filter or sort
  by [column]? Should an index be added?

## Side-effects

- **If context shows a notification system**: Should this trigger any notifications? If yes,
  which channel(s) — [list channels from context]?
- **If context shows a caching layer**: Does this invalidate or update any cached data
  (e.g., [cache name])? Who is responsible for invalidation?
- **If context shows event publishing / messaging**: Should this publish any events or
  trigger downstream processing?
- **If context shows background schedulers**: Does this interact with any scheduled jobs?

## Auth and access

- **If the feature adds new endpoints or mutations**: What authentication is required
  ([auth options from context])? Is there a per-resource ownership check needed?
- **If context shows role-based access control**: Which roles can use this feature?

## Testing

- **If context shows specific test patterns**: Should this be covered by [test type from
  context] or unit tests? Are there existing tests that need updating?

## Design

Trigger when the feature creates a new module / service / endpoint / scheduled job, or
when CODEBASE_CONTEXT.md offers more than one plausible home for this functionality.

- **If trigger fired**: How should the new functionality integrate with the existing
  [closest domain]? Is there an alternative — extending an existing class, reusing an
  existing service — that you considered or want considered?
- **If trigger fired**: What are the explicit boundaries of this feature — what does it
  own, and what should it deliberately NOT touch?

## Security

Trigger when the task description, elicitation context, or affected code mentions any of:
auth, login, password, token, secret, payment, API key, file upload, user input,
PII (email, phone, SSN, address), file path from user, outbound HTTP, raw SQL.

- **If trigger fired**: What constraints must the input satisfy — format, length,
  allowed characters, escaping or encoding requirements?
- **If trigger fired**: Are there fields in the request, response, or persisted state
  that must NOT appear in logs (tokens, secrets, PII)?
- **If trigger fired**: Who is the realistic attacker for this surface — anonymous user,
  authenticated low-privilege user, third-party caller, internal service?
