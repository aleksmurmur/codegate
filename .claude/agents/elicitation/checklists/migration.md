# Database Migration Elicitation Checklist

Each item is a trigger. Ask it only if the condition is true.
Replace bracketed placeholders with actual names from CODEBASE_CONTEXT.md.

---

## Change description

- **If not fully specified**: What exactly is changing — add column, drop column, rename,
  new table, add index, backfill?
- **Always**: Is this additive-only (safe to deploy before app change) or does it
  modify/remove existing data (requires coordinated deploy)?

## Data safety

- **If migration touches a table with existing data**: Approximately how many rows are
  affected? Is a data backfill needed — if so, what is the transformation?
- **Always**: What is the rollback plan if the migration fails halfway?
- **If migration makes a nullable column NOT NULL or adds a constraint**: Are there
  existing rows that would violate this constraint?

## Performance and downtime

- **If migration uses ALTER TABLE on a large table**: Does this require a table lock?
  Is zero-downtime deployment required?
- **If yes to zero-downtime**: What is the strategy — expand-contract, online DDL,
  shadow column?
- **If context shows the DB is [Postgres / MySQL]**: Will any new indexes be created
  with CONCURRENTLY (Postgres) or online algorithm (MySQL)?

## Dependencies

- **If app code and migration must ship together**: Which app change must be deployed
  first — migration or code?
- **If context shows other services or the HTMX UI reads this table**: Are there other
  consumers of this table that need updating?
- **If migration changes a column type or removes a nullable**: Does this break any
  existing API contracts?

## Indexing

- **If migration adds a column used in WHERE/ORDER BY/JOIN**: Does the new column
  need an index?
- **If context shows [migration tool] versioning**: Which version number should this
  migration use? Are there pending migrations in other branches?
