---
name: cg-flow-feedback
description: Codegate debug mode — record how the workflow itself performed. Use at the end of each phase only when the marker file .ai/cg-debug-mode exists.
user-invocable: false
---

# Flow feedback (debug mode)

Active only while `.ai/cg-debug-mode` exists (`/cg-debug on|off`). Purpose: first-hand
observations about how the flow performs on a real task — for improving codegate itself.

At the end of each phase append to `{session dir}/flow-feedback.md`:

```markdown
## Phase N — {Name} ({timestamp})

**Worked well**:
- {observation}

**Friction**:
- {observation}

**Could improve**:
- {observation}

**Missing in flow**:
- {observation}
```

1–4 bullets per section; an empty one is `- (none observed)`. What to look at, per phase:
elicitation — question count against task size, which questions surfaced real ambiguity;
planning — plan size, integrity and pattern-review usefulness; implementation — chunking
against the plan, red-check discipline, ADRs written or missed, scope drift; quality gate —
real findings against noise, false negatives you noticed, coverage refresh; PR — description
completeness, what the PR creator had to guess.

After Phase 5 add the session summary:

```markdown
---

## Session summary ({timestamp})

**Top wins**:
- {3–5}

**Top pain points**:
- {3–5}

**Suggested flow improvements (ranked)**:
1. {a concrete change to a skill / prompt / script}

**Things missing from the flow**:
- {capabilities or guardrails you wished existed}
```

Be specific ("elicitation asked 9 questions for a 1-file change"), not abstract ("elicitation
was slow"). A smooth phase is `- (no friction observed)` — negative signal beats filler.
Tell the user once: "Flow feedback recorded at `{session dir}/flow-feedback.md`."
