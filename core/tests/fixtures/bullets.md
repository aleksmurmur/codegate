# Plan — bullet-variant fixture

Exercises the loosened parser: dash bullet, asterisk bullet, missing period,
leading indent.

## Acceptance Criteria

1. Plan parser accepts dash-bullet checklist lines.
2. Plan parser accepts asterisk-bullet checklist lines.
3. Plan parser accepts indented checklist lines.

## Checklist

- [ ] 1. Modify CLAUDE.md — dash bullet
* [ ] 2. Modify .claude/settings.json — asterisk bullet
[ ] 3 Modify .claude/scripts/plan-integrity.py — no period after number
  [ ] 4. Modify .claude/scripts/tests/run-tests.sh — leading indent

## Commit Plan

1. refactor: tweak CLAUDE.md and settings — items 1, 2
2. refactor: tighten plan-integrity and its tests — items 3, 4
