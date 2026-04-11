# Linter Detection and Configuration Guide

Used by the CIE to identify which linters apply to the detected stack,
check whether they are configured, and add rules based on discovered conventions.

**Rule**: Only append to existing configs. Never remove or overwrite existing rules.
If a config file doesn't exist, create it with a comment marking CIE-generated rules.

---

## Stack → Linter Mapping

| Stack | Linters to check |
|---|---|
| Kotlin | ktlint (required), detekt (optional static analysis) |
| Java | Checkstyle (required), PMD (optional), SpotBugs (optional) |
| TypeScript / JavaScript | ESLint (required), Prettier (optional) |
| Python | flake8 or ruff (required), black (optional), mypy (optional), isort (optional) |
| Go | golangci-lint (required) |
| Scala | scalafmt (required), scalafix (optional) |
| Ruby | RuboCop (required) |
| Rust | rustfmt (required), clippy (required) |
| Multi-language | Apply rules for each language found |

---

## Kotlin — ktlint

**Detection**: Look for any of:
- `.editorconfig` with `[*.{kt,kts}]` section
- `ktlint` in `build.gradle(.kts)` plugins or dependencies
- `.ktlint` directory or `.ktlintrc`

**Config file**: `.editorconfig` (preferred) or `ktlint.editorconfig`

**If not configured**: Create `.editorconfig` with a `[*]` base section and `[*.{kt,kts}]` section.

**Rules to add based on discoveries**:

| Discovery | Rule to add |
|---|---|
| Consistent 4-space indent | `indent_size = 4` in `[*]` |
| No trailing whitespace observed | `trim_trailing_whitespace = true` |
| LF line endings in repo | `end_of_line = lf` |
| Max line length convention (~120) | `max_line_length = 120` in `[*.{kt,kts}]` |
| Wildcard imports not used | `ktlint_standard_no-wildcard-imports = enabled` |
| No semicolons used | `ktlint_standard_no-semi = enabled` |
| Single expression functions used consistently | `ktlint_standard_function-expression-body = enabled` |

**Example generated section**:
```ini
# Added by codegate CIE on {date}
[*.{kt,kts}]
indent_size = 4
max_line_length = 120
ktlint_standard_no-wildcard-imports = enabled
```

---

## Kotlin — detekt (optional static analysis)

**Detection**: Look for `detekt` in `build.gradle(.kts)` plugins or a `detekt.yml` / `detekt/` directory.

**Config file**: `detekt.yml` or `detekt/detekt.yml`

**If not configured**: Skip — detekt requires more setup than can be auto-generated. Log a tech debt entry recommending its addition.

**If configured**: Check that these are enabled (they catch common AI-written code issues):
- `complexity.LongMethod` (flag methods over 50 lines)
- `complexity.TooManyFunctions` (flag classes with too many responsibilities)
- `style.MagicNumber` (flag unexplained numeric literals)
- `potential-bugs.EqualsAlwaysReturnsTrueOrFalse`

---

## Java — Checkstyle

**Detection**: Look for:
- `checkstyle.xml` in project root or `config/checkstyle/`
- `checkstyle` plugin in `build.gradle` or `pom.xml`

**Config file**: `config/checkstyle/checkstyle.xml` (conventional location)

**If not configured**: Create `config/checkstyle/checkstyle.xml` with a minimal ruleset.

**Rules to add based on discoveries**:

| Discovery | Checkstyle module |
|---|---|
| Consistent indentation observed | `TreeWalker/Indentation` |
| Javadoc on public methods | `JavadocMethod` (only if existing code has Javadoc) |
| No wildcard imports | `AvoidStarImport` |
| Max line length | `LineLength` |

---

## TypeScript / JavaScript — ESLint

**Detection**: Look for:
- `.eslintrc`, `.eslintrc.js`, `.eslintrc.json`, `.eslintrc.yml`
- `eslint.config.js`, `eslint.config.mjs` (flat config, ESLint 9+)
- `eslint` in `package.json` devDependencies

**Config file**: Use whatever format already exists. If none: create `eslint.config.js` (flat config).

**If not configured**: Create minimal `eslint.config.js`.

**Rules to add based on discoveries**:

| Discovery | Rule |
|---|---|
| No `var` used anywhere | `"no-var": "error"` |
| Consistent use of `const` over `let` | `"prefer-const": "error"` |
| Strict equality used | `"eqeqeq": "error"` |
| No console.log in source (only tests) | `"no-console": "warn"` |
| Single quotes used consistently | `"quotes": ["error", "single"]` |
| Semicolons used/not used consistently | `"semi": ["error", "always"]` or `"never"` |
| TypeScript strict null checks apparent | Enable `@typescript-eslint/no-explicit-any` |

---

## Python — flake8 / ruff

**Detection**:
- `.flake8` or `[flake8]` section in `setup.cfg` or `tox.ini`
- `ruff.toml` or `[tool.ruff]` in `pyproject.toml`
- `flake8` or `ruff` in `requirements*.txt` or `pyproject.toml` dev dependencies

**Config file**: `.flake8` (for flake8) or `pyproject.toml` `[tool.ruff]` section (for ruff).

**Rules to add based on discoveries**:

| Discovery | Config |
|---|---|
| Max line length observed (~88 or 120) | `max-line-length = 88` |
| Imports grouped (stdlib / third-party / local) | Enable `isort` or `ruff.lint.select = ["I"]` |
| Type hints used consistently | Enable `mypy` or `ruff.lint.select += ["ANN"]` |

---

## Go — golangci-lint

**Detection**: Look for `.golangci.yml`, `.golangci.yaml`, `.golangci.toml`, `.golangci.json`

**Config file**: `.golangci.yml`

**If not configured**: Create `.golangci.yml` with standard linters enabled.

**Standard linters to enable** (if not already):
```yaml
linters:
  enable:
    - gofmt
    - govet
    - errcheck
    - staticcheck
    - unused
    - gosimple
```

---

## Ruby — RuboCop

**Detection**: `.rubocop.yml` in project root

**Config file**: `.rubocop.yml`

**Rules to add**: Based on discoveries about method length, naming, complexity.

---

## Rust — rustfmt + clippy

**Detection**:
- `rustfmt.toml` or `.rustfmt.toml` for rustfmt
- Clippy config in `Cargo.toml` `[lints.clippy]` section

**Both are standard with Rust toolchain** — if not configured, create `rustfmt.toml` with defaults
and add `[lints.clippy]` to `Cargo.toml`.

---

## How to apply updates

1. Read this file to identify relevant linters for the detected stack
2. For each linter:
   a. Check if the config file exists
   b. If yes: read it, then append new rules in a clearly marked section
   c. If no: create it with a header comment and the new rules
3. Always add a comment before CIE-generated rules:
   ```
   # Added by codegate CIE on {date} — remove or adjust as needed
   ```
4. After updating, report in CODEBASE_CONTEXT.md under "Linter Status"
