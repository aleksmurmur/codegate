# Finding format

One scale and one shape for every finding the quality gate, its lenses and the independent
review report.

## Severity

- **Critical** — users or data get hurt if this ships: a wrong result, data loss or corruption,
  a security hole, a broken contract, required behaviour missing or untested. Blocks the PR/MR
  until fixed or overridden.
- **Warning** — a real consequence, but limited or unlikely. Fixed now or recorded (tech debt,
  PR/MR description).
- **Info** — worth knowing, no consequence you can name. The gate does not report it.

When unsure between two levels, take the higher and say why in the finding.

## Why it matters

Every Critical and Warning names its concrete consequence in one sentence: who sees what, what
data goes wrong, what breaks under which load. No abstractions ("bad practice", "code smell",
"not clean"). A finding whose consequence you cannot name is Info, or nothing.

## Shape

In a report:

```
**[Critical|Warning] <rule section> — <title>** [no override]
`path:line` — what is wrong, in one or two sentences.
**Why it matters**: <the consequence>.
```

In a one-line list: `- [path:line] — problem — consequence`.

Several findings with one root cause at different places are one finding: the subject is the
incomplete list, every known place is named under it, and the fix is to derive the complete list
mechanically (grep every caller, enumerate every route) — the places nobody looked at are still
there. Rate it by its worst place, one level higher when that one is a Warning.

## No override

Mark a Critical `[no override]` when it is one of:

- a `Security:` acceptance criterion unimplemented or untested;
- injection: SQL or query, command, path, or user-controlled HTML/script rendered unsanitized;
- a secret in the code, in client-shipped config, or in logs;
- a missing access check on a protected resource, or another user's or tenant's data reachable.

Such a finding is fixed; the user's override of a gate FAIL does not let it through. It can be withdrawn only by showing it is wrong.

## Gate verdict

Any Critical → **FAIL**. Otherwise any Warning → **WARN**. Otherwise **PASS**.
