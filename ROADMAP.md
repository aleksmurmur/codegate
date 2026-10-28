# Roadmap

## Next

- **Look at [Elephant-Goldfish Model](https://github.com/google/elephant-goldfish-model) and take what fits.**
  Its phases 1–2 counterpart is weaker on grounding (no data map, no mechanical checks, heavy gates),
  but it critiques the design before code: five fresh reviewers (design critic, zoom-out/YAGNI,
  comprehension, implementation readiness, doc vs code). Our plan review is barred from judging merit,
  so the first fresh look at the design comes in Phase 4, after the code. Candidates:
  - a zero-context critic on `PLAN.md` in Phase 2 (design-critic + implementation-readiness lenses);
  - a mandatory alternatives section in the plan;
  - `egm-drift-report` — checked-in docs vs current source.
