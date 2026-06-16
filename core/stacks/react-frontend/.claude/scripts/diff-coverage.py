#!/usr/bin/env python3
"""Diff coverage check — every meaningful new/modified line of production code
must be exercised by at least one test.

React-frontend variant. Reads existing coverage reports produced by Vitest or
Jest (Istanbul JSON, lcov). Falls back to a grep-based test-reference check:
every new/modified symbol (function, exported const, component, hook) must
appear in at least one test file.

v0 supports:
    - Istanbul JSON (coverage/coverage-final.json) — Vitest v8 default, Jest default
    - lcov.info (coverage/lcov.info) — older convention; some tools still emit it
    - grep-based symbol fallback (TypeScript / JavaScript)

Usage:
    diff-coverage.py --base <commit> --output <path>

Exit codes:
    0 — CLEAN
    1 — FAIL (uncovered new code or missing test references)
    2 — script could not run (bad inputs, git not available)
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# --- Path classification -----------------------------------------------------

TEST_PATH_MARKERS = (
    "/__tests__/",
    "/tests/",
    "/test/",
    "/__test__/",
    "/spec/",
)
TEST_FILENAME_PATTERNS = [
    re.compile(r".*\.test\.(ts|tsx|js|jsx|mjs|cjs)$"),
    re.compile(r".*\.spec\.(ts|tsx|js|jsx|mjs|cjs)$"),
    re.compile(r".*\.e2e\.(ts|tsx|js|jsx)$"),  # Playwright/Cypress E2E
]
EXCLUDED_PREFIXES = (
    ".ai/",
    ".claude/",
    ".git/",
    ".next/",
    ".nuxt/",
    ".storybook/",
    ".turbo/",
    ".vite/",
    "build/",
    "coverage/",
    "dist/",
    "node_modules/",
    "out/",
    "public/",
    "storybook-static/",
)
EXCLUDED_SUFFIXES = (
    ".md",
    ".mdx",
    ".yml",
    ".yaml",
    ".toml",
    ".json",
    ".lock",
    ".gitignore",
    ".editorconfig",
    ".css",
    ".scss",
    ".sass",
    ".less",
    ".svg",
    ".png",
    ".jpg",
    ".jpeg",
    ".webp",
    ".ico",
    ".woff",
    ".woff2",
    ".html",
)
# Files inside src/ that match these names are config/declaration, not exec code.
EXCLUDED_FILENAMES = (
    "vite-env.d.ts",
    "global.d.ts",
    "types.d.ts",
)
PRODUCTION_EXTENSIONS = {".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"}


def is_test_path(path: str) -> bool:
    if any(m in f"/{path}" for m in TEST_PATH_MARKERS):
        return True
    name = Path(path).name
    return any(p.match(name) for p in TEST_FILENAME_PATTERNS)


def is_production_path(path: str) -> bool:
    if any(path.startswith(p) for p in EXCLUDED_PREFIXES):
        return False
    if any(path.endswith(s) for s in EXCLUDED_SUFFIXES):
        return False
    if Path(path).name in EXCLUDED_FILENAMES:
        return False
    if is_test_path(path):
        return False
    return Path(path).suffix in PRODUCTION_EXTENSIONS


# --- Meaningful-line filter --------------------------------------------------

TRIVIAL_LINE = re.compile(
    r"^\s*("
    r"//.*|"                      # single-line comment
    r"/\*.*|\*.*|\*/.*|"          # block comment marks
    r"import\s+.*|"               # ES module import
    r"export\s+\*.*|"             # re-export *
    r"export\s+\{[^}]*\}\s*;?\s*$|"  # `export { Foo, Bar };` lines (no body)
    r"export\s+type\s+.*[=;].*|"  # `export type X = ...` (declaration; runs only at compile)
    r"type\s+\w+\s*=.*;?\s*$|"    # plain `type X = ...`
    r"interface\s+\w+\s*\{?\s*$|" # interface opener
    r"\}\s*;?\s*$|"               # closing brace
    r"[\{\}\(\)\[\];,]*\s*"       # pure punctuation / empty
    r")$"
)


def is_meaningful(line: str) -> bool:
    """True for lines that represent real executable code (not type-only)."""
    if not line.strip():
        return False
    return TRIVIAL_LINE.match(line) is None


# --- Git diff parsing --------------------------------------------------------

@dataclass
class Hunk:
    path: str
    added_lines: dict[int, str]  # line_number -> source text


def run_git(*args: str) -> str:
    try:
        return subprocess.check_output(
            ["git", *args], text=True, stderr=subprocess.DEVNULL
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"error: git command failed: git {' '.join(args)}", file=sys.stderr)
        raise SystemExit(2) from e


def get_added_lines(base: str) -> dict[str, dict[int, str]]:
    """Return {production_path: {line_number: line_text}} of added/modified
    meaningful lines in the diff base..HEAD.
    """
    diff = run_git("diff", "--unified=0", f"{base}..HEAD")
    result: dict[str, dict[int, str]] = {}
    current_path: str | None = None
    current_line: int | None = None

    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:]
            current_path = path if is_production_path(path) else None
            continue
        if line.startswith("+++ "):
            current_path = None
            continue
        if line.startswith("@@") and current_path:
            m = re.search(r"\+(\d+)(?:,(\d+))?", line)
            if m:
                current_line = int(m.group(1))
            continue
        if current_path and line.startswith("+") and not line.startswith("+++"):
            content = line[1:]
            if current_line is not None and is_meaningful(content):
                result.setdefault(current_path, {})[current_line] = content
            if current_line is not None:
                current_line += 1

    return result


# --- Istanbul JSON parsing ---------------------------------------------------

ISTANBUL_GLOBS = [
    "coverage/coverage-final.json",
    "coverage/.tmp/coverage-final.json",
    "**/coverage/coverage-final.json",
]


def find_istanbul_report() -> Path | None:
    root = Path(".")
    for pattern in ISTANBUL_GLOBS:
        for candidate in root.glob(pattern):
            if candidate.is_file():
                return candidate
    return None


def parse_istanbul(json_path: Path) -> dict[str, set[int]]:
    """Return {source_path: {covered_line_numbers}} from an Istanbul coverage-
    final.json. Istanbul tracks statements, not lines per se — but each statement
    has a start line; if its hit count is > 0, that line is covered. We map
    every statement whose hit count > 0 to its start line.

    Paths in Istanbul JSON are absolute on the runner's filesystem. We normalize
    to repo-relative by finding the longest common suffix against the keys.
    """
    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        print(f"warn: could not read Istanbul report: {e}", file=sys.stderr)
        return {}

    covered: dict[str, set[int]] = {}
    for abs_path, file_data in data.items():
        statement_map = file_data.get("statementMap") or {}
        statement_hits = file_data.get("s") or {}
        lines: set[int] = set()
        for stmt_id, hit_count in statement_hits.items():
            try:
                hits = int(hit_count)
            except (TypeError, ValueError):
                continue
            if hits <= 0:
                continue
            stmt = statement_map.get(stmt_id) or statement_map.get(str(stmt_id))
            if not stmt:
                continue
            try:
                start_line = int(stmt["start"]["line"])
                end_line = int(stmt.get("end", {}).get("line", start_line))
            except (KeyError, TypeError, ValueError):
                continue
            for ln in range(start_line, end_line + 1):
                lines.add(ln)
        if lines:
            covered[abs_path] = lines
    return covered


def match_istanbul_path(diff_path: str, covered_map: dict[str, set[int]]) -> set[int]:
    """Istanbul keys are absolute filesystem paths; diff paths are repo-relative.
    Match by longest suffix.
    """
    # Direct hit (rare, but cheap to try)
    if diff_path in covered_map:
        return covered_map[diff_path]
    best: set[int] = set()
    best_len = -1
    for key, lines in covered_map.items():
        if key.endswith("/" + diff_path) or key.endswith(diff_path):
            # Prefer the longest matching key (most specific)
            if len(key) > best_len:
                best = lines
                best_len = len(key)
    return best


# --- lcov parsing ------------------------------------------------------------

LCOV_GLOBS = [
    "coverage/lcov.info",
    "coverage/lcov-report/lcov.info",
    "**/coverage/lcov.info",
]


def find_lcov_report() -> Path | None:
    root = Path(".")
    for pattern in LCOV_GLOBS:
        for candidate in root.glob(pattern):
            if candidate.is_file():
                return candidate
    return None


def parse_lcov(lcov_path: Path) -> dict[str, set[int]]:
    """Return {source_path: {covered_line_numbers}} from an lcov.info file.

    Format (relevant lines):
        SF:<absolute or relative path>
        DA:<line>,<count>
        end_of_record

    A line is "covered" if its DA count is > 0.
    """
    covered: dict[str, set[int]] = {}
    current_path: str | None = None
    current_lines: set[int] = set()
    try:
        text = lcov_path.read_text(encoding="utf-8")
    except OSError as e:
        print(f"warn: could not read lcov report: {e}", file=sys.stderr)
        return {}
    for line in text.splitlines():
        if line.startswith("SF:"):
            current_path = line[3:].strip()
            current_lines = set()
        elif line.startswith("DA:") and current_path is not None:
            try:
                ln_str, count_str = line[3:].split(",", 1)
                ln = int(ln_str)
                count = int(count_str.split(",")[0])  # may have a checksum suffix
            except (ValueError, IndexError):
                continue
            if count > 0:
                current_lines.add(ln)
        elif line.strip() == "end_of_record" and current_path is not None:
            if current_lines:
                covered[current_path] = current_lines
            current_path = None
            current_lines = set()
    return covered


def match_lcov_path(diff_path: str, covered_map: dict[str, set[int]]) -> set[int]:
    """Same suffix-matching strategy as Istanbul."""
    if diff_path in covered_map:
        return covered_map[diff_path]
    best: set[int] = set()
    best_len = -1
    for key, lines in covered_map.items():
        if key.endswith("/" + diff_path) or key.endswith(diff_path):
            if len(key) > best_len:
                best = lines
                best_len = len(key)
    return best


# --- Grep fallback -----------------------------------------------------------

SYMBOL_DEFS = [
    # Named function declarations
    re.compile(r"\bfunction\s+(\w+)\s*\("),
    re.compile(r"\bexport\s+function\s+(\w+)\s*\("),
    re.compile(r"\bexport\s+default\s+function\s+(\w+)\s*\("),
    re.compile(r"\bexport\s+async\s+function\s+(\w+)\s*\("),
    # Arrow / function-expression bound to const/let
    re.compile(r"\bexport\s+const\s+(\w+)\s*(?::\s*[^=]+)?=\s*(?:async\s+)?(?:\([^)]*\)|\w+)\s*=>"),
    re.compile(r"\bconst\s+(\w+)\s*(?::\s*[^=]+)?=\s*(?:async\s+)?(?:\([^)]*\)|\w+)\s*=>"),
    # React component pattern: const Foo: FC = ...
    re.compile(r"\bexport\s+const\s+([A-Z]\w+)\s*:\s*(?:FC|React\.FC|FunctionComponent)"),
    # Catch-all for exported value bindings: zod schemas (z.object(...)),
    # constants, computed values, forwardRef/memo wrappers, anything else.
    # The arrow-only patterns above miss these.
    re.compile(r"\bexport\s+const\s+(\w+)\s*[:=]"),
    re.compile(r"\bexport\s+let\s+(\w+)\s*[:=]"),
    # Class declarations
    re.compile(r"\bexport\s+class\s+(\w+)\b"),
    re.compile(r"\bclass\s+(\w+)\s*(?:extends|\{)"),
]


def extract_new_symbols(added: dict[str, dict[int, str]]) -> set[str]:
    symbols: set[str] = set()
    for lines in added.values():
        for text in lines.values():
            for pattern in SYMBOL_DEFS:
                m = pattern.search(text)
                if m and len(m.group(1)) >= 3:
                    symbols.add(m.group(1))
    return symbols


def list_test_files() -> list[str]:
    try:
        out = subprocess.check_output(["git", "ls-files"], text=True)
    except subprocess.CalledProcessError:
        return []
    return [p for p in out.splitlines() if is_test_path(p)]


def grep_in_files(symbol: str, files: list[str]) -> bool:
    if not files:
        return False
    try:
        subprocess.check_output(
            ["git", "grep", "-q", "--", rf"\b{re.escape(symbol)}\b", "--", *files],
            stderr=subprocess.DEVNULL,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


# --- Reporting ---------------------------------------------------------------

def write_report(
    path: Path,
    mode: str,
    result: str,
    summary: list[str],
    uncovered: list[str],
) -> None:
    lines = [
        "# Coverage Report",
        "",
        f"**Result**: {result}",
        f"**Mode**: {mode}",
        "",
        "## Summary",
    ]
    lines.extend(f"- {s}" for s in summary)
    lines.append("")
    if uncovered:
        lines.append("## Uncovered")
        lines.extend(f"- {u}" for u in uncovered)
        lines.append("")
        lines.append("## Next step")
        lines.append("Add at least one test exercising each item above, commit,")
        lines.append("then re-run `/cg-approve implementation`.")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


# --- Main --------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Diff coverage check (React frontend)")
    parser.add_argument("--base", required=True, help="Base commit (e.g. merge-base with main)")
    parser.add_argument("--output", required=True, help="Path to write coverage-report.md")
    args = parser.parse_args()

    output = Path(args.output)
    added = get_added_lines(args.base)

    if not added:
        write_report(
            output, mode="n/a", result="CLEAN",
            summary=["No production code changes in this diff."],
            uncovered=[],
        )
        print("Coverage: CLEAN (no production changes)")
        sys.exit(0)

    # Prefer Istanbul JSON (richer info), fall back to lcov, fall back to grep.
    istanbul = find_istanbul_report()
    lcov = None if istanbul else find_lcov_report()

    if istanbul is not None:
        covered_map = parse_istanbul(istanbul)
        mode_label = f"Istanbul ({istanbul})"
    elif lcov is not None:
        covered_map = parse_lcov(lcov)
        mode_label = f"lcov ({lcov})"
    else:
        covered_map = None
        mode_label = None

    if covered_map is not None:
        uncovered: list[str] = []
        touched_lines = 0
        covered_lines = 0
        matcher = match_istanbul_path if istanbul is not None else match_lcov_path
        for path, lines in added.items():
            project_cov = matcher(path, covered_map)
            for nr, text in lines.items():
                touched_lines += 1
                if nr in project_cov:
                    covered_lines += 1
                else:
                    uncovered.append(f"{path}:{nr}  {text.strip()[:80]}")
        result = "CLEAN" if not uncovered else "FAIL"
        write_report(
            output, mode=mode_label, result=result,
            summary=[
                f"Production files touched: {len(added)}",
                f"New/modified meaningful lines: {touched_lines}",
                f"Covered: {covered_lines}",
                f"Uncovered: {len(uncovered)}",
            ],
            uncovered=uncovered,
        )
        print(f"Coverage: {result} ({mode_label.split(' (')[0]})")
        print(f"  Touched: {touched_lines}   Covered: {covered_lines}   Uncovered: {len(uncovered)}")
        print(f"  Report:  {output}")
        sys.exit(1 if uncovered else 0)

    # Fallback: grep-based symbol check
    new_symbols = extract_new_symbols(added)
    test_files = list_test_files()
    if not test_files:
        write_report(
            output, mode="grep (no test files found)", result="CLEAN",
            summary=[
                "No test files found in the repository.",
                "Coverage check skipped. Add tests when a test harness exists.",
            ],
            uncovered=[],
        )
        print("Coverage: CLEAN (fallback — no tests in repo)")
        sys.exit(0)

    missing = [s for s in sorted(new_symbols) if not grep_in_files(s, test_files)]
    result = "CLEAN" if not missing else "FAIL"
    write_report(
        output, mode="grep (no coverage tool detected)", result=result,
        summary=[
            f"Production files touched: {len(added)}",
            f"New/modified symbols found: {len(new_symbols)}",
            f"Symbols without any test reference: {len(missing)}",
            "Note: grep fallback checks symbol names, not execution paths.",
            "Run tests with coverage (Vitest: `vitest run --coverage`; Jest: `jest --coverage`)",
            "for a stronger check.",
        ],
        uncovered=[f"symbol `{s}` is not referenced by any test file" for s in missing],
    )
    print(f"Coverage: {result} (grep fallback)")
    print(f"  Symbols checked: {len(new_symbols)}   Missing: {len(missing)}")
    print(f"  Report:  {output}")
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
