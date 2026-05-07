# Plan — commit-plan-coverage fixture

Commit Plan misses item 2 and references item 3 twice. Must FAIL with
MIRAGES_FOUND.

## Acceptance Criteria

1. Commit Plan covers every checklist item.
2. Each item belongs to exactly one commit.
3. Coverage gaps are surfaced as mirages.

## Checklist

[ ] 1. Modify CLAUDE.md — tweak wording
[ ] 2. Modify README.md — update examples
[ ] 3. Modify .claude/scripts/plan-integrity.py — tighten parser

## Commit Plan

1. refactor: tweak CLAUDE.md — items 1
2. refactor: tighten plan-integrity script — items 3
3. refactor: extra cleanup — items 3
