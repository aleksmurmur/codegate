#!/usr/bin/env python3
"""Diff coverage check — every meaningful new/modified line of production code
must be exercised by at least one test.

Reads existing coverage reports produced by the project's test run. If no
coverage report is found, falls back to a grep-based test-reference check:
every new/modified symbol in production code must appear in at least one
test file.

v0 supports:
    - JaCoCo XML reports (JVM / Gradle / Maven)
    - grep-based symbol fallback (any language)

Additional formats (Istanbul, coverage.py, go cover) slot in as small adders
alongside parse_jacoco().

Scope: the diff is computed against committed history (``base..HEAD``), not the
working tree. Uncommitted edits and reverts are invisible to this check. Commit
before running, and after changing a file to address an uncovered line, commit
that change before re-running — otherwise the report still reflects the previous
commit, not your working tree.

Usage:
    diff-coverage.py --base <commit> --output <path>

Exit codes:
    0 — CLEAN
    1 — FAIL (uncovered new code or missing test references)
    2 — script could not run (bad inputs, git not available)
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# --- Path classification -----------------------------------------------------

TEST_PATH_MARKERS = (
    "/test/",
    "/tests/",
    "/__tests__/",
    "/spec/",
)
TEST_FILENAME_PATTERNS = [
    re.compile(r".*Test\.(kt|java|scala)$"),
    re.compile(r".*Tests\.(kt|java|scala)$"),
    re.compile(r".*Spec\.(kt|java|scala|rb)$"),
    re.compile(r".*\.test\.(ts|tsx|js|jsx|mjs)$"),
    re.compile(r".*\.spec\.(ts|tsx|js|jsx|mjs)$"),
    re.compile(r"test_.*\.py$"),
    re.compile(r".*_test\.py$"),
    re.compile(r".*_test\.go$"),
    re.compile(r".*_spec\.rb$"),
]
EXCLUDED_PREFIXES = (
    ".ai/",
    ".claude/",
    ".git/",
    "build/",
    "dist/",
    "out/",
    "target/",
    "node_modules/",
    ".gradle/",
    "vendor/",
    "__pycache__/",
)
EXCLUDED_SUFFIXES = (
    ".md",
    ".yml",
    ".yaml",
    ".toml",
    ".json",
    ".gradle",
    ".gradle.kts",
    ".properties",
    ".xml",
    ".lock",
    ".gitignore",
    ".editorconfig",
    "CLAUDE.md",
    "README.md",
)
PRODUCTION_EXTENSIONS = {
    ".kt", ".java", ".scala", ".groovy",
    ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs",
    ".py", ".go", ".rs", ".rb", ".cs", ".php",
}


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
    if is_test_path(path):
        return False
    return Path(path).suffix in PRODUCTION_EXTENSIONS


# --- Meaningful-line filter --------------------------------------------------

TRIVIAL_LINE = re.compile(
    r"^\s*("
    r"//.*|"                      # single-line comment
    r"#.*|"                       # python / shell comment
    r"/\*.*|\*.*|\*/.*|"          # block comment marks
    r"import\s+.*|from\s+.*|"     # imports
    r"using\s+.*|include\s+.*|"   # cpp-ish includes
    r"package\s+.*|"              # kotlin/java package
    r"[\{\}\(\)\[\];,]*\s*"       # pure punctuation / empty
    r")$"
)


def is_meaningful(line: str) -> bool:
    """True for lines that represent real executable code."""
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
            ["git", *args], text=True, encoding="utf-8", errors="replace", stderr=subprocess.DEVNULL
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"error: git command failed: git {' '.join(args)}", file=sys.stderr)
        raise SystemExit(2) from e


def get_added_lines(base: str) -> dict[str, dict[int, str]]:
    """Return a dict {production_path: {line_number: line_text}} of added/modified
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


# --- JaCoCo parsing ----------------------------------------------------------

JACOCO_GLOBS = [
    "build/reports/jacoco/*/jacocoTestReport.xml",
    "build/reports/jacoco/test/jacocoTestReport.xml",
    "target/site/jacoco/jacoco.xml",
    "**/jacoco.xml",
]


def find_jacoco_report() -> Path | None:
    root = Path(".")
    for pattern in JACOCO_GLOBS:
        for candidate in root.glob(pattern):
            if candidate.is_file():
                return candidate
    return None


def parse_jacoco(xml_path: Path) -> tuple[dict[str, set[int]], dict[str, set[int]]]:
    """Return (covered, executable) maps {source_relative_path: {line numbers}}.

    `covered`    = lines with ci > 0 (at least one covered instruction).
    `executable` = every line JaCoCo emits a `<line>` for, i.e. every line that
                   carries bytecode.

    Lines absent from `executable` are non-executable — declarations, function
    signatures, interface/data-class/sealed bodies, `private set`, `companion`,
    `const`, pure punctuation. JaCoCo never marks them covered, so counting them
    as "uncovered" is a false positive. Callers must restrict the coverage check
    to lines present in `executable`.
    """
    import xml.etree.ElementTree as ET

    covered: dict[str, set[int]] = {}
    executable: dict[str, set[int]] = {}
    tree = ET.parse(xml_path)
    root = tree.getroot()

    for package in root.iter("package"):
        pkg_name = package.get("name", "")  # e.g. com/example/service
        for sourcefile in package.iter("sourcefile"):
            fname = sourcefile.get("name", "")
            key = f"{pkg_name}/{fname}" if pkg_name else fname
            cov: set[int] = set()
            exe: set[int] = set()
            for line in sourcefile.iter("line"):
                try:
                    nr = int(line.get("nr", "0"))
                    ci = int(line.get("ci", "0"))
                except ValueError:
                    continue
                exe.add(nr)
                if ci > 0:
                    cov.add(nr)
            if exe:
                executable[key] = exe
            if cov:
                covered[key] = cov
    return covered, executable


def match_jacoco_path(diff_path: str, covered_map: dict[str, set[int]]) -> set[int]:
    """JaCoCo keys look like `com/example/foo/Bar.kt`. Diff paths are repo-relative
    (`src/main/kotlin/com/example/foo/Bar.kt`). Match by suffix.
    """
    for key, lines in covered_map.items():
        if diff_path.endswith(key):
            return lines
    return set()


# --- Grep fallback -----------------------------------------------------------

SYMBOL_DEFS = [
    re.compile(r"\bfun\s+(\w+)\s*\("),                    # Kotlin
    re.compile(r"\bdef\s+(\w+)\s*\("),                    # Python / Scala
    re.compile(r"\bfunc\s+(?:\([^)]+\)\s+)?(\w+)\s*\("),  # Go
    re.compile(r"\bfn\s+(\w+)\s*\("),                     # Rust
    re.compile(
        r"\b(?:public|private|protected|internal|static|async)?\s*"
        r"(?:function\s+)?(\w+)\s*\(.*?\)\s*(?::|\{)"
    ),  # JS/TS/Java methods (rough)
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
        out = subprocess.check_output(["git", "ls-files"], text=True, encoding="utf-8", errors="replace")
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
    parser = argparse.ArgumentParser(description="Diff coverage check")
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

    jacoco = find_jacoco_report()

    if jacoco is not None:
        try:
            covered_map, executable_map = parse_jacoco(jacoco)
        except Exception as e:
            print(f"warn: could not parse JaCoCo report: {e}", file=sys.stderr)
            covered_map, executable_map = {}, {}
        uncovered: list[str] = []
        touched_lines = 0
        covered_lines = 0
        # A populated report means JaCoCo ran. A production file absent from it was
        # excluded from instrumentation (e.g. the build's jacoco config drops
        # `**/api/**/dto/**` and serializer stubs) — not measurable, so don't count it.
        report_has_data = bool(executable_map)
        for path, lines in added.items():
            project_cov = match_jacoco_path(path, covered_map)
            project_exe = match_jacoco_path(path, executable_map)
            if report_has_data and not project_exe:
                continue
            for nr, text in lines.items():
                # Skip non-executable lines (declarations, signatures, etc.): JaCoCo
                # emits no bytecode for them, so they can never be "covered". Only
                # count lines JaCoCo recognizes as executable. (When executable data
                # is missing entirely — parse error — project_exe is empty and we fall
                # back to counting every line, the original conservative behavior.)
                if project_exe and nr not in project_exe:
                    continue
                touched_lines += 1
                if nr in project_cov:
                    covered_lines += 1
                else:
                    uncovered.append(f"{path}:{nr}  {text.strip()[:80]}")
        result = "CLEAN" if not uncovered else "FAIL"
        write_report(
            output, mode=f"JaCoCo ({jacoco})", result=result,
            summary=[
                f"Production files touched: {len(added)}",
                f"New/modified meaningful lines: {touched_lines}",
                f"Covered: {covered_lines}",
                f"Uncovered: {len(uncovered)}",
            ],
            uncovered=uncovered,
        )
        print(f"Coverage: {result} (JaCoCo)")
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
            "Install a coverage tool (JaCoCo, c8, coverage.py, go cover) for a stronger check.",
        ],
        uncovered=[f"symbol `{s}` is not referenced by any test file" for s in missing],
    )
    print(f"Coverage: {result} (grep fallback)")
    print(f"  Symbols checked: {len(new_symbols)}   Missing: {len(missing)}")
    print(f"  Report:  {output}")
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
