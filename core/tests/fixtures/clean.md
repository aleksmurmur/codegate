# Plan — clean fixture

## Task Summary

Minimal plan referencing files codegate installs into every project.
These fixtures run from the project root, not from cg-core.

## Acceptance Criteria

1. Given codegate is installed, when CLAUDE.md is opened, then phase rules are clear.
2. Given a fresh checkout, when .claude/settings.json is read, then hooks are wired.
3. Must-not: documentation must not contain stale phase references.

## Checklist

[ ] 1. Modify CLAUDE.md — tweak wording
[ ] 2. Modify .claude/settings.json — update examples

## Commit Plan

1. refactor: tweak CLAUDE.md wording — items 1
2. refactor: update settings — items 2
