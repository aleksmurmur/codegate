# Bug Fix Elicitation Checklist

## Reproduction
- How do you reproduce the bug? (steps, inputs, environment)
- Is it reproducible consistently or intermittent?
- When did it start? (after a deploy, always existed, after a data change?)

## Impact
- Who is affected? (all users, specific users, specific conditions)
- What is the severity? (data loss, downtime, cosmetic, performance)
- Is there a workaround users can use right now?

## Expected vs actual
- What should happen?
- What actually happens?
- Any error messages, stack traces, or log lines?

## Root cause hypothesis
- Do you have any idea where in the code this originates?
- Has anyone looked at logs or metrics related to this?

## Scope of fix
- Should the fix be minimal (patch only what's broken) or is a broader fix appropriate?
- Are there other places in the code with the same bug pattern?
- Does fixing this require a data migration or backfill?
