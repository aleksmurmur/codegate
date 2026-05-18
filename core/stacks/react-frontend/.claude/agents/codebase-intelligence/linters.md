# Linter Detection and Configuration Guide — React frontend

Used by the CIE to identify which linters apply, check whether they are
configured, and add rules based on discovered conventions.

**Rule**: Only append to existing configs. Never remove or overwrite existing rules.
If a config file doesn't exist, create it with a comment marking CIE-generated rules.

---

## Stack → Linter Mapping

| Concern | Linter |
|---|---|
| JS / TS code quality | ESLint (required) |
| JS / TS formatting | Prettier (required if no `prettier` ignored) |
| TypeScript correctness | `tsc --noEmit` (required if tsconfig present) |
| CSS / Tailwind class ordering | `prettier-plugin-tailwindcss` (optional, common) |
| Commit hygiene | husky + lint-staged (optional) |

---

## ESLint

**Detection**: Look for any of:
- `eslint.config.js`, `eslint.config.mjs`, `eslint.config.ts` (flat config, ESLint 9+)
- `.eslintrc`, `.eslintrc.js`, `.eslintrc.json`, `.eslintrc.yml`, `.eslintrc.cjs`
- `eslint` in `package.json` devDependencies (config might be in package.json `eslintConfig`)

**Config file**: Use whatever format already exists. Strongly prefer the flat config
(`eslint.config.js`) for new setups — legacy `.eslintrc.*` is being phased out.

**If not configured**: Create `eslint.config.js` with the flat-config preset for React/TS.
Use the project's actual TypeScript version. Don't add rules whose conventions you
haven't observed.

**Rules to add based on discoveries**:

| Discovery | Rule |
|---|---|
| `eslint-plugin-react-hooks` not enabled | Enable `react-hooks/rules-of-hooks` and `react-hooks/exhaustive-deps` — NEVER skip these |
| `eslint-plugin-jsx-a11y` not enabled and project has interactive UI | Enable recommended set |
| No `var` used anywhere | `"no-var": "error"` |
| Consistent use of `const` over `let` | `"prefer-const": "error"` |
| Strict equality used | `"eqeqeq": "error"` |
| No `console.log` outside dev/log utilities | `"no-console": ["warn", { "allow": ["warn", "error"] }]` |
| `import/order` patterns observed (groups, blank line between) | Enable `eslint-plugin-import` `import/order` |
| Path alias `@` used | Configure `import/resolver` to recognize it; consider `no-relative-parent-imports` |
| TypeScript strict mode on, narrow `any` use | `"@typescript-eslint/no-explicit-any": "warn"` (or `"error"` if zero observed) |
| Unused exports common | `"@typescript-eslint/no-unused-vars": ["error", { "argsIgnorePattern": "^_" }]` |
| `useEffect` blocks with disabled-comment overrides observed | Tech debt entry — do NOT add a rule that masks this; surface it |
| Hooks named `use*` strictly | rules-of-hooks already covers; ensure plugin enabled |

**Critical**: `react-hooks/exhaustive-deps` must be ENABLED. If the project has
disabled it globally or with many file-level overrides, that is a tech-debt
entry — not a rule to perpetuate.

**Example generated section** (flat config):
```js
// Added by codegate CIE on {date} — review and adjust as needed
import reactHooks from 'eslint-plugin-react-hooks';
import jsxA11y from 'eslint-plugin-jsx-a11y';

export default [
  // ... existing configs ...
  {
    files: ['**/*.{ts,tsx,js,jsx}'],
    plugins: { 'react-hooks': reactHooks, 'jsx-a11y': jsxA11y },
    rules: {
      'react-hooks/rules-of-hooks': 'error',
      'react-hooks/exhaustive-deps': 'error',
      'jsx-a11y/anchor-is-valid': 'error',
      'no-var': 'error',
      'prefer-const': 'error',
      'eqeqeq': 'error',
      'no-console': ['warn', { allow: ['warn', 'error'] }],
    },
  },
];
```

---

## Prettier

**Detection**: Look for any of:
- `.prettierrc`, `.prettierrc.json`, `.prettierrc.yaml`, `.prettierrc.js`,
  `prettier.config.js`, `prettier.config.mjs`
- `prettier` key in `package.json`
- `.prettierignore` (implies Prettier is used even if config is default)

**Config file**: `.prettierrc` or `prettier.config.js` — use existing.

**If not configured**: Create `.prettierrc` with the observed defaults (don't impose
opinions the codebase doesn't have).

**Rules to add based on discoveries**:

| Discovery | Config |
|---|---|
| 2-space indentation used | `"tabWidth": 2` |
| Single quotes in source | `"singleQuote": true` |
| Trailing commas in multi-line objects | `"trailingComma": "all"` |
| Lines wrap around 100 chars | `"printWidth": 100` |
| Tailwind classes consistently sorted | Note `prettier-plugin-tailwindcss` in devDeps; if absent and Tailwind is used, suggest adding it (tech debt entry) |

---

## TypeScript (`tsc --noEmit` as a "linter")

**Detection**: `tsconfig.json` in project root.

**Not a config file you edit blindly** — TypeScript settings change behavior, not just
formatting. Note the following in CODEBASE_CONTEXT.md gotchas:

| Setting | If true | If false / missing |
|---|---|---|
| `strict` | Whole strict family on | TS won't catch null-undefined-mismatch bugs |
| `noUncheckedIndexedAccess` | `arr[i]` is `T \| undefined` | Array indexing silently nullable-unaware |
| `exactOptionalPropertyTypes` | `foo?: string` cannot be `undefined` literal | Less strict; some patterns subtly differ |
| `noImplicitAny` (covered by `strict`) | Forces type annotations | Implicit `any` allowed |
| `verbatimModuleSyntax` | Imports without `type` get emitted | TS auto-elides type-only imports |

If `strict` is OFF, that's not a CIE rule-add — that's a tech-debt entry recommending
turning it on, with an estimate of how many errors would surface (sample a few files).

---

## How to apply updates

1. Read this file to identify relevant linters for the detected stack
2. For each linter:
   a. Check if the config file exists
   b. If yes: read it, then append new rules in a clearly marked section
   c. If no: create it with a header comment and the new rules
3. Always add a comment before CIE-generated rules:
   ```
   // Added by codegate CIE on {date} — remove or adjust as needed
   ```
   (Use `#` for YAML, `//` for JS/TS/JSON-with-comments.)
4. After updating, report in CODEBASE_CONTEXT.md under "Linter Status"
