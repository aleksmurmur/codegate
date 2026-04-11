# Feature Elicitation Checklist

Minimum questions to answer before planning a new feature.
Not all apply to every feature — skip if clearly not relevant.

## Requirements
- What is the exact expected behavior? (happy path)
- What should happen on error / invalid input?
- Are there any edge cases that need special handling?
- Are there any constraints (performance, data size, rate limits)?

## Scope and affected areas
- Which domain(s) does this touch?
- Does it affect any existing endpoints or change existing behavior?
- Are there any downstream consumers of this data (other services, events, caches)?
- Should this trigger any events, notifications, or side-effects?

## Data / persistence
- Does this require schema changes?
- If yes: is this additive (new column/table) or destructive (modify/drop)?
- What is the expected data volume? (affects indexing decisions)
- Is rollback needed / possible if something goes wrong?

## API / interface
- What does the request/response look like?
- Who calls this? (other services, frontend, external clients)
- What authentication/authorization is required?

## Testing
- What scenarios must be covered by tests?
- Are there any existing integration tests that need updating?
