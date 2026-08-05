# Plan — bullet-variant fixture

Exercises the loosened parser: dash bullet, asterisk bullet, missing period,
leading indent.

## Acceptance Criteria

1. Plan parser accepts dash-bullet checklist lines.
2. Plan parser accepts asterisk-bullet checklist lines.
3. Plan parser accepts indented checklist lines.

## Checklist

- [ ] 1. Modify core/shared/CLAUDE.md — dash bullet
* [ ] 2. Modify README.md — asterisk bullet
[ ] 3 Modify core/shared/.claude/scripts/plan-integrity.py — no period after number
  [ ] 4. Modify core/shared/.claude/settings.json — leading indent

## Commit Plan

1. refactor: tweak core/shared/CLAUDE.md and README — items 1, 2
2. refactor: tighten plan-integrity and settings — items 3, 4
