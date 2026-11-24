Override a quality gate FAIL for the current session. Argument: $ARGUMENTS

Phases proceed by themselves, so `quality` is the one approval left: the user accepts the
FAIL items the gate could not get fixed.

Find this checkout's session: `python3 .claude/scripts/cg_session.py dir` → `.ai/sessions/{id}`.
None: say "No active session. Start one with /cg-feature, /cg-bugfix, or /cg-refactor." Stop.

- **Any argument but `quality`** (`quick`, `elicit`, `plan`, `implementation` belonged to a
  mode that no longer exists): say "Phases proceed by themselves — nothing to approve.
  `/cg-status` shows where the task is." Stop.
- **`quality`**, state not `QUALITY_REVIEWED`: explain that there is no gate verdict to
  override in state `<state>`, and what comes next (`/cg-status`). Stop.
- **`quality`**, state `QUALITY_REVIEWED`, verdict in `{dir}/QUALITY_REPORT.md`:
  - `FAIL` with a finding marked `[no override]` (`.claude/agents/quality-gate/finding-format.md`):
    refuse — that finding has to be fixed. Stop.
  - `FAIL`: audit `[ts] Quality gate override by user — FAIL items accepted`, then continue.
  - `PASS` / `WARN`: nothing to override; continue.

  Continue: `python3 .claude/scripts/cg_session.py checked` succeeds → the review has run:
  Phase 5 (skill `cg-phase-5`). The audit has `Independent review started` → finish it
  (skill `cg-phase-4`, §5). Otherwise run the independent review (skill `cg-phase-4`, §5) —
  it writes `checked-sha`, which the push gate requires — then Phase 5.
