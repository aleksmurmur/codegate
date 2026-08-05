# Plan — create-collision fixture

A plan that creates a file whose name already exists as a symbol in the repo.
Non-blocking by design: a name collision is a hint to look, not a verdict.

## Acceptance Criteria

1. Given a plan creating a new file, when its stem already names a repo symbol, then a warning is emitted.
2. Given such a plan, when integrity runs, then the verdict is still CLEAN.
3. Must-not: a name collision must not block plan approval.

## Design Notes

New file sits beside the existing checklist handling. Deliberately collides.

## Checklist

[ ] 1. Create src/Checklist.kt — new file whose stem already exists as a symbol
[ ] 2. Modify README.md — mention it

## Commit Plan

1. feat: add Checklist — items 1
2. refactor: mention it in the README — items 2
