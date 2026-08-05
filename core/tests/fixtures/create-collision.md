# Plan — create-collision fixture

A plan that creates a file whose stem already exists as a word in the repo.
`Checklist` is guaranteed present: CLAUDE.md documents the plan's `## Checklist`
section. Fixtures run from the project root, not from cg-core.
Non-blocking by design: a name collision is a hint to look, not a verdict.

## Acceptance Criteria

1. Given a plan creating a new file, when its stem already names a repo symbol, then a warning is emitted.
2. Given such a plan, when integrity runs, then the verdict is still CLEAN.
3. Must-not: a name collision must not block plan approval.

## Design Notes

New file sits beside the existing checklist handling. Deliberately collides.

## Checklist

[ ] 1. Create src/Checklist.kt — new file whose stem already exists as a symbol
[ ] 2. Modify CLAUDE.md — mention it

## Commit Plan

1. feat: add Checklist — items 1
2. refactor: mention it in CLAUDE.md — items 2
