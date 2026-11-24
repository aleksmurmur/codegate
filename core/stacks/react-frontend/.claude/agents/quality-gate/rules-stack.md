# Quality gate rules — React frontend

Additions to the sections of `rules-common.md` (same numbers), then this stack's own sections.

## 1. Mechanical results — additions

ESLint findings from `react-hooks/rules-of-hooks`, `react-hooks/exhaustive-deps` and `jsx-a11y/*`
catch real bugs: each is a Critical (a Warning when a tech-debt entry already records the
pattern), and the fix never silences the rule. A TypeScript error is Critical; every
`@ts-expect-error` / `@ts-ignore` the diff adds needs its justification. No ESLint and no type
check configured → Warning, and a tech-debt entry recommending both.

## 3. Who else reads and writes — additions

Shared data here: store slices and selectors, query cache keys, context values, props, route
parameters, API response fields. Follow them through the components, hooks and selectors that
use them; a changed prop or hook return keeps its type but may change its meaning.

## 5. Conventions — additions

Component and hook naming (`PascalCase` components, `use*` hooks), feature folder vs shared
placement, server state through the project's server-state library, forms through the project's
form library, one styling approach, the import alias.

## 7. Tests — grep checks

Run on every changed test file; paste the output.

| # | Check | Pattern | Severity when unjustified |
|---|---|---|---|
| a | Loose assertion on a deterministic value — use exact equality, or justify inline | `toBeTruthy\|toBeDefined\|toContain\(` | Critical |
| b | Sleep-based wait — use `findBy*` / `waitFor` / `act` | `setTimeout\(\|sleep\(\|new Promise.*setTimeout` | Warning |
| c | Snapshot of ordinary render output — erodes under refactors, rarely catches the right bug | `toMatchSnapshot\(` | Critical |
| d | Test id where an accessible query works (`getByRole`, `getByLabelText`, `getByText`) | `getByTestId\|queryByTestId\|findByTestId` | Warning |
| e | Implementation details instead of behaviour | `\.state\(\|setState\(\|\.instance\(\)\|wrapper\.find\(` | Critical |

Also by reading: loading, empty and error states tested; keyboard and focus behaviour tested
where it matters; a test mocking more than three hooks or modules wants a network-level mock
instead.

## 8. Security — additions

What the browser executes:

- **XSS**: `dangerouslySetInnerHTML`, `innerHTML`, `document.write`, `eval`, `new Function()` —
  user or API content through them without a sanitizer (DOMPurify or equivalent). Dynamic `href`
  / `iframe src` must reject `javascript:` and `data:`; `target="_blank"` needs
  `rel="noopener noreferrer"` (Warning).
- **Tokens**: stored the way the project stores them (an HttpOnly cookie project keeps new
  tokens out of `localStorage`); never in a URL, never logged to the console or an error tracker;
  logout clears them client-side and on the server.
- **The bundle is public**: build-time variables (`VITE_`, `REACT_APP_`, `NEXT_PUBLIC_`) never
  hold secrets; only publishable third-party keys; sourcemaps not shipped to users.
- **Fetches**: state-changing calls carry the project's CSRF header; `credentials: 'include'`
  only where the backend allows it; dev-server proxies that relax CORS stay out of production.
- **Open redirect**: a navigation target read from the URL, `postMessage` or storage is checked
  to be same-origin or allow-listed.
- **Dependencies**: a new package is flagged with its version range and any install script
  (Warning without a reason in the diff).
- **CSP**: new inline script, `eval` or third-party origin that needs loosening the policy.

## S1. Data fetching and caching — lens: arch

- Server state in `useState` filled by an effect-driven fetch instead of the project's
  server-state library.
- Query keys from the project's key factory, not inline strings that miss invalidation.
- A mutation that changes server state invalidates the queries that show it; an optimistic
  update rolls back on error.
- A fetching effect cancels or guards on unmount (AbortController), or rapid navigation shows the
  wrong data.
- A list whose items each fetch (N+1 in render).
- Suspense boundaries where the fallback means something; refetch-on-focus left as the project
  set it.

Critical: server state in `useState` after a manual fetch, a key that will not invalidate, a
missing invalidation, an optimistic update without rollback, an effect dependency missing so it
loops or reads stale. Warning: a borderline cleanup omission, a redundant query, a boundary that
may flash.

## S2. Effects and rendering — lens: arch

- An effect that syncs state with an event belongs in the handler; one that derives state from
  props belongs in render or `useMemo`.
- Every value used inside an effect, memo or callback is in its dependency array; no inline
  object, array or function literal there.
- Listeners added in an effect are removed in its cleanup.
- Long lists virtualized; heavy work in render memoized; context values memoized.
- Prop drilling three or more levels for shared state; a new Context where the project already
  has a store; a HOC or render prop where a hook would do.

Critical: an effect syncing an event, a listener without cleanup, an unbounded user-controlled
list without virtualization. Warning: the rest.

## S3. Accessibility — lens: arch

- `<div onClick>` without a role, `tabIndex` and keyboard handling; an icon-only button without an
  accessible name; a form field without a label; a dialog without focus management (focus in on
  open, back on close, Esc) → Critical.
- State shown by colour alone, a skipped heading level, async updates outside a live region →
  Warning.

## S4. Error feedback — lens: arch

A new mutation with no error feedback to the user, or a render path with no error boundary above
it → Critical. 4xx shown distinct from 5xx and network failure; a loading state for new async
work; specific error messages where they help → Warning when missing.
