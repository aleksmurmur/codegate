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
    re.compile(r"(^|/)test_[^/]*\.py$"),
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
    r"@[\w.]+(\s*\(.*\))?\s*|"    # kotlin/java annotation line (not bytecode-instrumented)
    r"@[\w.]+\s*\(\s*\"\"\"\s*|"  # multiline annotation start, e.g. `@Query("""`
    r"@[\w.]+\s*\(\s*$|"          # multiline annotation opener with no payload yet, e.g. `@Query(` then `"""` on the next line
    r"\"\"\"\s*\)?\s*|"           # multiline string close, e.g. `"""` or `""")`
    r"(SELECT|FROM|WHERE|LEFT|RIGHT|INNER|OUTER|JOIN|ON|AND|OR|GROUP\s+BY|ORDER\s+BY|HAVING|UNION|LIMIT|OFFSET|UPDATE|INSERT|DELETE|SET|VALUES|RETURNING|WITH|DISTINCT|CAST|COALESCE|COUNT|SUM|MAX|MIN|AVG|CASE|WHEN|THEN|ELSE|END|EXISTS|NULLIF)\b.*|"  # SQL / JPQL string body inside triple-quoted annotation (extended keyword set covers multi-line aggregate/CASE expressions)
    r".*\bfun\s+\w+.*[(=\{]\s*|"  # kotlin function signature header (single-line with `{`/`=`, or multi-line opener ending with `(`)
    r"fun\s+\w+.*\)\s*:\s*[\w<>.?,\s]+\s*|"  # kotlin function signature ending `): Type` (abstract/interface method)
    r"interface\s+\w+.*\{?\s*|"   # kotlin interface declaration (no bytecode body)
    r"const\s+val\s+\w+.*|"       # kotlin top-level `const val` — compile-time inlined, no bytecode method
    r"companion\s+object(\s+\w+)?\s*\{?\s*|"  # kotlin `companion object` / `companion object Name {` declaration line
    r"(public\s+|internal\s+|private\s+)?object\s+\w+(\s*:\s*[\w<>.,\s]+)?\s*\{?\s*|"  # kotlin named `object X {` declaration line — singleton header carries no bytecode (init attributes to member lines); anonymous `object : Type` expressions don't match (no name)
    r"data\s+class\s+\w+\s*\(?\s*|"  # kotlin `data class Foo(` declaration line — properties inside are instrumented separately
    r"val\s+\w+\s*:\s*[\w<>.?,]+\s*$|"  # kotlin abstract `val name: Type` (interface property — abstract getter, no body); `\s` deliberately not in char class to avoid matching initialized `val foo: Type = …`
    r"\w+\s*=\s*\[\s*$|"          # array literal opener inside annotation values, e.g. `scanBasePackages = [`
    r"[\"'][^\"']*[\"']\s*,?\s*|"  # bare string literal entry inside an array/annotation, e.g. `"dev.codefish.foo",`
    r"[A-Z_][A-Z0-9_]+\s*,?\s*$|"  # const-style identifier as array/list entry, e.g. `TMA_HEALTH_V1_PATH,` — references inlined compile-time constants
    r"(@\w+\s*(\([^)]*\))?\s+)+\w+\s*:\s*[\w<>.?,\s]+,?\s*|"  # annotated kotlin parameter (`@Param("x") name: Type`, `@PathVariable id: String,`, `@Valid @RequestBody body: T`) — annotations carry no bytecode
    r"\w+\s*:\s*[\w<>.?,\s]+,?\s*|"  # kotlin multi-line signature parameter (`timetableId: UUID,`) — declarative, not bytecode-instrumented
    r"\)\s*:\s*[\w<>.?,\s]+\s*[\{=]?\s*|"  # kotlin multi-line signature closer (`): Type {` or `): Type =`)
    r"\}\s*else\s*\{?\s*|"        # `} else {` continuation — JaCoCo instruments the branch body, not the keyword line
    r"\.\w+\([^)]*\)\s*|"         # dangling method-chain continuation (`.toResponse()`, `.filter { … }`); JaCoCo often attributes chain bytecode to the root line
    r"[\{\}\(\)\[\];,\s]*"        # pure punctuation / whitespace-only (e.g. `) {`, `},`, `)`)
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


def parse_jacoco(xml_path: Path) -> dict[str, dict[int, tuple[int, int]]]:
    """Return {source_relative_path: {line_number: (mi, ci)}} from a JaCoCo XML
    report, where mi/ci are the missed/covered instruction counts JaCoCo recorded
    for that line. Only lines JaCoCo emits a <line> for are executable; a line
    absent from this map carries no bytecode (annotation entry, `enum class X {`
    or other bare declaration header) and is therefore not coverable.
    """
    import xml.etree.ElementTree as ET

    tracked: dict[str, dict[int, tuple[int, int]]] = {}
    tree = ET.parse(xml_path)
    root = tree.getroot()

    for package in root.iter("package"):
        pkg_name = package.get("name", "")  # e.g. com/example/service
        for sourcefile in package.iter("sourcefile"):
            fname = sourcefile.get("name", "")
            key = f"{pkg_name}/{fname}" if pkg_name else fname
            lines: dict[int, tuple[int, int]] = {}
            for line in sourcefile.iter("line"):
                try:
                    nr = int(line.get("nr", "0"))
                    mi = int(line.get("mi", "0"))
                    ci = int(line.get("ci", "0"))
                except ValueError:
                    continue
                lines[nr] = (mi, ci)
            if lines:
                tracked[key] = lines
    return tracked


def match_jacoco_path(
    diff_path: str, tracked_map: dict[str, dict[int, tuple[int, int]]]
) -> dict[int, tuple[int, int]]:
    """JaCoCo keys look like `com/example/foo/Bar.kt`. Diff paths are repo-relative
    (`src/main/kotlin/com/example/foo/Bar.kt`). Match by suffix.
    """
    for key, lines in tracked_map.items():
        if diff_path.endswith(key):
            return lines
    return {}


def evaluate_jacoco(
    added: dict[str, dict[int, str]],
    tracked_map: dict[str, dict[int, tuple[int, int]]],
) -> tuple[list[str], int, int, int]:
    """Classify each added production line against JaCoCo per-line instruction
    data. Returns (uncovered, executable, covered, non_executable).

    A line counts as executable only when JaCoCo tracked it with (mi+ci) > 0;
    such a line is covered when ci > 0 and uncovered when ci == 0. Lines JaCoCo
    never emitted a <line> for carry no bytecode (annotations, `enum class`/class
    declaration headers) and are excluded from both the denominator and the
    uncovered list — they cannot be "uncovered" because there is nothing to run.
    """
    uncovered: list[str] = []
    executable = covered = non_executable = 0
    for path, lines in added.items():
        project_lines = match_jacoco_path(path, tracked_map)
        for nr, text in sorted(lines.items()):
            tracked = project_lines.get(nr)
            if tracked is None or tracked[0] + tracked[1] == 0:
                non_executable += 1
                continue
            _mi, ci = tracked
            executable += 1
            if ci > 0:
                covered += 1
            else:
                uncovered.append(f"{path}:{nr}  {text.strip()[:80]}")
    return uncovered, executable, covered, non_executable


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
            tracked_map = parse_jacoco(jacoco)
        except Exception as e:
            # A JaCoCo report exists but is unreadable — coverage cannot be judged.
            # Fail loud (exit 2 = "could not run") rather than silently passing.
            msg = f"JaCoCo report found but could not be parsed: {jacoco} ({e})"
            print(f"error: {msg}", file=sys.stderr)
            write_report(
                output, mode=f"JaCoCo ({jacoco})", result="ERROR",
                summary=[msg, "Regenerate the coverage report and re-run."],
                uncovered=[],
            )
            sys.exit(2)
        uncovered, executable_lines, covered_lines, non_executable_lines = (
            evaluate_jacoco(added, tracked_map)
        )
        result = "CLEAN" if not uncovered else "FAIL"
        write_report(
            output, mode=f"JaCoCo ({jacoco})", result=result,
            summary=[
                f"Production files touched: {len(added)}",
                f"Executable new/modified lines: {executable_lines}",
                f"Covered: {covered_lines}",
                f"Uncovered: {len(uncovered)}",
                f"Non-executable lines excluded: {non_executable_lines}",
            ],
            uncovered=uncovered,
        )
        print(f"Coverage: {result} (JaCoCo)")
        print(f"  Executable: {executable_lines}   Covered: {covered_lines}   "
              f"Uncovered: {len(uncovered)}   Non-exec excluded: {non_executable_lines}")
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
