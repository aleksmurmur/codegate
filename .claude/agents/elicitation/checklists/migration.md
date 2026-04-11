# Database Migration Elicitation Checklist

## Change description
- What exactly is changing? (add column, drop column, rename, add table, add index, etc.)
- Is this additive-only or does it modify/remove existing data?

## Data safety
- Does this migration touch tables with existing production data?
- Approximately how many rows are affected?
- Is a data backfill needed? If so, what is the transformation?
- What is the rollback plan if something goes wrong?

## Performance and downtime
- Does this require a table lock? (ALTER TABLE on large tables)
- Is zero-downtime deployment required?
- If yes: what is the strategy? (expand-contract, online DDL, etc.)

## Dependencies
- Are there application changes that must be deployed before, with, or after this migration?
- Are there other services that read this table that need updating?
- Does this change any API contracts (e.g., fields that were nullable become required)?

## Indexing
- Does the new/changed column need an index?
- If adding an index to a large table: will it be created concurrently (CONCURRENTLY in Postgres)?
