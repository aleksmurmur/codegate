# Quality gate rules — JVM backend

Additions to the sections of `rules-common.md` (same numbers), then this stack's own sections.

## 3. Who else reads and writes — additions

Shared data here: tables, columns, entity fields, cache keys, events and messages, API response
fields. Follow them through repositories, mappers, consumers and scheduled jobs.

## 5. Conventions — additions

Layers (no business logic in controllers, no persistence logic outside the data layer); the
project's exception types and their mapping to responses; constructor injection; the DTO and
mapping approach the context records.

## 7. Tests — grep checks

Run on every changed test file; paste the output.

| # | Check | Pattern | Severity when unjustified |
|---|---|---|---|
| a | Loose assertion on a deterministic value — use exact equality, or justify inline (a generated id with no way to read it back) | `isNotNull\|isNotEmpty\|isNotBlank\|contains(` | Critical |
| b | Sleep-based wait — poll or wait for the condition instead | `sleep\(\|Thread\.sleep\|delay\(` | Warning |
| c | Range assertion hiding non-determinism — only for a value that cannot be controlled (wall clock with no injected clock) | `isBetween\|isGreaterThan\|isLessThan\|isAfter\|isBefore` | Warning |
| d | Setup in a test body | `\.setup\|\.prepare\|\.configure\|\.init\(` outside fixtures | Warning |

## 8. Security — additions

- **Injection**: new SQL or query strings parameterized, never concatenated with input; ORM
  calls whose field or column names come from input; dynamic procedure names.
- **CSRF**: a new state-changing endpoint on cookie sessions keeps the framework's protection on.
- **Outbound calls** (SSRF): URLs, paths or commands built from input go through an allow-list;
  outbound timeouts are set.
- **Files**: paths from input are normalized and jailed to a base directory; archive entries are
  checked for `..` (zip slip).
- New columns holding sensitive data fall under the project's encryption and access rules.

## S1. Database — lens: arch

For new queries, schema changes and ORM use:

- N+1: a query per item in a loop, a lazy association read in a loop without a fetch join,
  entity graph or batch fetch.
- Transaction boundaries at the layer the context records.
- List endpoints paginated, or bounded by construction.
- Columns used in `WHERE` / `ORDER BY` / `JOIN` indexed.
- Every schema change has a migration, following the project's versioning convention.
- **A heavy query on a frequent path.** For each new or changed query, find how often it runs:
  follow it to its entry points — a list or page load, a check on every request, a job over
  every row. On a frequent path, judge its cost from the query itself, JPQL and derived
  queries by the SQL they turn into: joins across large tables, a subquery or aggregate per
  row, a scan with no index to use, everything loaded and then filtered in memory.
- **A migration that rewrites existing data.** One that updates or backfills existing rows,
  or alters a table in a way that rewrites or locks it. The design or the plan must say so:
  which tables, how much data, what is locked and for how long, and why not a cheaper way
  (in batches, a new column filled alongside, computed at read time). Said → check the
  migration matches what was said.

Critical: a confirmed N+1, an unbounded list that can grow, a schema change without a
migration, a heavy query on a frequent path, a data-rewriting migration the design and the
plan do not explain (whoever approved it did not know what they approved).
Warning: a possible N+1 that needs a closer look, an index that may be needed, a query whose
cost you cannot judge from the code (say what to check: its plan on realistic data).

## S2. Resources — lens: arch

- Heavy resources (connection pools, HTTP clients, thread pools, large caches) created per
  request or inside a loop → Critical.
- Opened connections, streams and files closed; listeners removed; caches bounded. Unclear
  lifecycle → Warning.
