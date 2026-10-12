Context-aware shortcut for `/cg-approve`. Optional argument: `$ARGUMENTS`.

If `$ARGUMENTS` is non-empty, treat it as an explicit phase name and run
`/cg-approve <args>` directly. Same semantics as the long form. Skip the
detection logic below.

Otherwise, infer the phase from session state and dispatch:

## Steps (no-arg form)

1. `python3 .claude/scripts/cg_session.py dir` → this checkout's session. If empty:
   - Say "No active session. Start with `/cg-feature`, `/cg-bugfix`, or
     `/cg-refactor`."
   - Stop.

1a. Read `.ai/sessions/{id}/mode` (default `interactive` if missing —
    backwards-compat for pre-mode sessions).
    If `mode=fast` (the default for new sessions), this session
    auto-proceeds and `/ok` is a no-op.
    Say: "Session is in fast mode (default) — phases auto-proceed; no
    approval needed. Use `/cg-status` to see the current phase. (To
    use approval gates, start sessions with `--interactive`.)" Stop.
    (Exception: if `state=QUALITY_REVIEWED` AND QUALITY_REPORT.md
    verdict is FAIL AND the user explicitly wants to override, they
    must use the long form `/cg-approve quality` — `/ok` will not
    override FAILs, in either mode.)

2. Read:
   - `.ai/sessions/{id}/state` — current phase
   - Existence of `.ai/sessions/{id}/elicitation.md`
   - Existence of `.ai/sessions/{id}/PLAN.md` (and check whether it begins
     with the fast-path classification line — see skill `cg-phase-1`)
   - Existence and content of `.ai/sessions/{id}/QUALITY_REPORT.md`
   - Last 5 lines of `.ai/sessions/{id}/audit.log`

3. Determine the right `/cg-approve` action by state:

   QUALITY_REVIEWED rows are checked top to bottom; the first that matches decides.

   | State | Other signal | Action |
   |---|---|---|
   | (no session) | — | `No active session.` (handled in step 1) |
   | IDLE | `elicitation.md` exists | run `/cg-approve elicit` |
   | IDLE | PLAN.md is a fast-path proposal (cosmetic classification) | run `/cg-approve quick` |
   | IDLE | neither — Phase 1 not finished | "Phase 1 hasn't completed — answer the elicitation questions first, or accept the fast-path proposal." Stop. |
   | ELICITED | — | run `/cg-approve plan` |
   | PLAN_APPROVED | — | run `/cg-approve implementation` (rare — state usually transitions to IMPLEMENTING immediately) |
   | IMPLEMENTING | — | run `/cg-approve implementation` |
   | QUALITY_REVIEWED | `checked-sha` present | run Phase 5 (skill `cg-phase-5`) |
   | QUALITY_REVIEWED | audit has `Independent review started` | the review is under way: continue Phase 4 §5; when it is waiting on "fix or proceed?", `/ok` means proceed |
   | QUALITY_REVIEWED | verdict `PASS`, or the audit has `WARN accepted` / `Quality gate override` | start Phase 4 §5 (the independent review) |
   | QUALITY_REVIEWED | verdict is `WARN` | run `/cg-approve quality`, but FIRST print: "⚠ Accepting WARN findings via /ok. Read QUALITY_REPORT.md if you haven't." |
   | QUALITY_REVIEWED | verdict is `FAIL` | **refuse**: "Quality gate is FAIL. /ok will not override FAIL — type `/cg-approve quality` explicitly to override (note: critical SQL/security FAILs cannot be overridden at all)." Stop. |
   | PR_CREATED / PR_UPDATED | — | "The PR/MR exists — nothing to approve. Fixes to it are rework; `/cg-merged` checks for a merge." Stop. |
   | REWORK | — | "Rework in progress — the delta check runs before the push (skill `cg-rework`). Nothing to approve." Stop. |
   | MERGED / ABANDONED | — | "The task is closed. New work starts a new task." Stop. |

4. Before running the inferred `/cg-approve XXX`, **announce it**:

   ```
   State: {STATE}. Running /cg-approve {phase} on your behalf.
   ```

   This gives the user a one-line audit and a chance to interrupt if
   the state was misread.

5. Then run `/cg-approve {phase}` (see `.claude/commands/cg-approve.md`)
   (i.e. trigger the same handler that the long form invokes — there is
   no separate code path).

## Edge cases

- **State file missing / unreadable**: say "Session state is unreadable
  (.ai/sessions/{id}/state). Use `/cg-status` to inspect; type the long-form
  /cg-approve explicitly." Stop.
- **Verdict line missing in QUALITY_REPORT.md**: treat as WARN by default
  (safer than implicit FAIL override) and print a notice.
- **User typed `/ok` but flow is somewhere unusual** (e.g., session is
  mid-fix-iteration): trust the state file. The dispatch table above is
  the source of truth.

## Why this exists

`/cg-approve {phase}` is typed many times per session. Inferring the phase
from state collapses 5 long forms into one short `/ok`. The long forms
remain as the explicit override and as the canonical, scriptable interface.

Both forms route through the same handler — `/ok` is purely a UX layer.
