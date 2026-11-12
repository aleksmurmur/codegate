# Roadmap

## Done

- **Design critique before the user sees the design** (from the
  [Elephant-Goldfish Model](https://github.com/google/elephant-goldfish-model)): the
  elicitation agent writes `design.md`, a fresh critic reads it with the code, and the
  options reach the user already challenged. Growth is weighed only when it has a source,
  by reversibility. Planning writes down the agreed design; the Phase 2 pattern review is
  gone (its prior-art check lives in the critic now). EGM's mandatory alternatives section
  was not taken: the draft already weighs options per decision.

## Later

- **Drift between `.ai/CODEBASE_CONTEXT.md` and the code.** It is written once by
  `/cg-context` and refreshed only by a full re-run. It records patterns rather than
  inventories, so it ages slowly, and the critic and planner read the code itself — revisit
  if stale context shows up in flow feedback.
