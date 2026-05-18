# Feature Elicitation Checklist — React frontend

Each item is a trigger. Ask it only if the condition is true.
Replace bracketed placeholders with actual names from CODEBASE_CONTEXT.md.

---

## Happy path and errors

- **Always**: What is the exact expected behavior on the happy path? Describe the screen
  or interaction (what the user sees, what they do, what changes).
- **If description is vague about failure cases**: What should happen when [API returns 4xx /
  network fails / response is empty / required field is missing]?
- **If context shows a normalized ApiError type**: Should errors surface as [inline field
  error / toast / banner / route-level error boundary]? Match what existing flows do unless
  there's a reason to deviate.

## Scope boundary

- **If description could naturally extend further**: Should the implementation stop at
  [inferred boundary] (e.g., just the list screen), or does it also include [adjacent thing]
  (e.g., the detail screen, the create form)?
- **If context shows multiple features are touched**: Does this change any behavior in
  [adjacent feature]? Should it?

## Loading and empty states

- **If feature involves async data**: What does the screen show while loading? Skeleton,
  spinner, the previous data with a refresh indicator, or nothing?
- **If feature shows a list**: What if the list is empty? Generic placeholder, illustration
  with CTA, or hidden section?
- **If feature has multiple async dependencies**: Show progressively as each resolves, or
  wait for all and show together?

## Optimistic updates

- **If feature is a mutation that the UI immediately reflects**: Should we optimistically
  update the cache before the server confirms? (Improves perceived performance; requires
  rollback handling on error.)
- **If yes**: What's the rollback UX — silent revert, toast, banner?

## Forms and validation

- **If feature involves a form**: Field-level validation triggers when (on blur, on
  change, on submit)? Match existing form conventions.
- **If form has dependencies between fields**: Which fields disable/clear which other
  fields? (E.g., changing "type" clears "subtype".)
- **If form is destructive (delete, archive)**: Confirmation pattern — inline confirm
  button toggle, modal dialog, type-the-name to confirm?

## State scope

- **If feature involves shared data across components**: Is this server state (cached from
  API → use the server-state lib) or client state (local UI concern → useState/local
  store)? Be explicit, this is the #1 React design mistake.
- **If feature crosses route boundaries**: Should state survive navigation? (URL params,
  global store, or refetch on each visit.)

## Accessibility (a11y)

- **Always**: Is this an interactive surface (button, link, form, custom widget)? If so,
  what's the keyboard interaction (Tab order, Enter to activate, Esc to close)?
- **If feature has a custom widget** (combobox, dropdown, dialog): Use a primitive from
  Radix/Headless rather than rolling your own — they get a11y right by default.
- **If feature has icons-only buttons**: Each needs `aria-label`. Confirm the label text.
- **If feature has color-coded states** (red = error, green = success): Is there a
  non-color signal (icon, text) for users who can't perceive the color difference?
- **If feature affects focus management**: After [action], where should focus land?

## Routing and URL state

- **If feature has filters/search/sort that the user might bookmark**: Should these go in
  the URL (search params) or local state? Match what existing list screens do.
- **If feature changes screens / opens a modal**: Should it be a route (so it's
  back-button-able and shareable) or a modal (so it doesn't affect history)?

## Mobile and responsive

- **If feature is a complex layout**: At what breakpoint does the layout change? Match
  the project's existing breakpoint conventions (typically Tailwind defaults).
- **If feature has touch interactions** (drag, swipe): Does it have a keyboard equivalent
  for desktop a11y?

## Caching and invalidation

- **If feature changes server state**: Which query keys need invalidation after success?
  (TanStack Query: list the keys explicitly.)
- **If feature reads data that could be stale**: Acceptable staleness window? Match the
  staleTime convention used elsewhere.

## Authorization / role gating

- **If feature should be role-gated**: Which role(s) can use it? Is the UI hidden
  entirely or shown disabled with a tooltip? (Remember: UI gating is UX, not security —
  the server enforces.)

## Analytics / telemetry

- **If context shows analytics is wired**: Should this feature emit events? Which? With
  what properties? Match existing event naming conventions.

## Performance budget

- **If feature loads a large dataset or expensive component**: Should it be code-split
  (`React.lazy`)? Lazy-loaded data with infinite scroll, or paginated?
- **If feature includes a heavy dependency**: Is dynamic import (`import('foo')`) the
  right boundary?

## i18n

- **If context shows i18n is set up (react-intl / i18next / FormatJS)**: All user-visible
  strings need translation keys. Confirm: namespace, fallback locale, plural rules if
  applicable.
- **If i18n is NOT set up**: That's fine — note it in the plan so reviewers don't ask.

## Out of scope (explicit non-goals)

- Always: What are the explicit non-goals — adjacent things this task should NOT do?
  This is the single best protection against scope drift mid-implementation.
