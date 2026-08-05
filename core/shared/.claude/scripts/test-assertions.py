#!/usr/bin/env python3
"""Test-assertion check — a test touched by this diff must assert something.

Coverage tells you a line ran. It does not tell you anything ran that would
notice if the line were wrong. A test whose body is `assertDoesNotThrow { ... }`
executes every line of the code under test and would still pass with that code
deleted and replaced by a stub. This script finds those tests mechanically,
before the LLM quality gate runs, so the gate is not the first thing asked to
notice.

Two tiers, deliberately separated so the blocking one stays precise:

    FAIL  — the test function asserts NOTHING, or asserts only that nothing
            threw. It cannot distinguish working code from a stub.
    WARN  — the test function's only assertions are existence checks
            (not-null / defined / truthy). Reported, never blocking: sometimes
            existence genuinely is the contract.

Only functions containing at least one line ADDED in this diff are examined.
Pre-existing weak tests in a file you happened to touch are not your problem.

Language support is a table, not a parser. When a file's functions cannot be
delimited confidently the file is reported as `unparsed` and never fails the
run — a check that guesses is worse than a check that abstains.

Usage:
    test-assertions.py --base <commit> [--output <path>]

Exit codes:
    0 — CLEAN (no FAIL-tier findings; WARN-tier may still be reported)
    1 — FAIL (at least one touched test asserts nothing or only no-throw)
    2 — script could not run (bad inputs, git not available)
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

# --- Which files are tests ---------------------------------------------------

TEST_PATH_MARKERS = ("/test/", "/tests/", "/__tests__/", "/spec/")
TEST_FILENAME_PATTERNS = [
    re.compile(r".*Test\.(kt|kts|java|scala|groovy)$"),
    re.compile(r".*Tests\.(kt|kts|java|scala|groovy)$"),
    re.compile(r".*Spec\.(kt|kts|java|scala|groovy|rb)$"),
    re.compile(r".*\.test\.(ts|tsx|js|jsx|mjs|cjs)$"),
    re.compile(r".*\.spec\.(ts|tsx|js|jsx|mjs|cjs)$"),
    re.compile(r"(^|/)test_[^/]*\.py$"),
    re.compile(r".*_test\.py$"),
    re.compile(r".*_test\.go$"),
    re.compile(r".*_spec\.rb$"),
    re.compile(r".*_test\.rb$"),
    re.compile(r".*_test\.exs$"),
    re.compile(r".*_test\.rs$"),
]


def is_test_path(path: str) -> bool:
    if any(marker in f"/{path}" for marker in TEST_PATH_MARKERS):
        return True
    return any(p.match(path) for p in TEST_FILENAME_PATTERNS)


# --- Language table ----------------------------------------------------------
#
# `starts` — regexes whose match means "a test function begins on this line".
# `style`  — how the body is delimited: "brace" or "indent".
#
# A language absent from this table yields `unparsed`, never a finding.

BRACE = "brace"
INDENT = "indent"


@dataclass(frozen=True)
class Language:
    name: str
    style: str
    # Declarations that MAY begin a test — checked against `marker` below.
    starts: tuple[re.Pattern[str], ...]
    # Declarations that begin a test on their own (DSL blocks that name a case).
    self_evident: tuple[re.Pattern[str], ...] = ()
    # When set, a `starts` match counts only if this appears on the declaration
    # line or in the annotations/comments immediately above it.
    marker: re.Pattern[str] | None = None
    line_comment: tuple[str, ...] = ("//",)
    block_comment: tuple[tuple[str, str], ...] = (("/*", "*/"),)
    quotes: tuple[str, ...] = ('"', "'", "`")


# Kotlin/Java/Scala/Groovy. A bare `fun name(` is NOT enough: test classes are
# full of private fixture builders that legitimately assert nothing, and
# flagging those is how a check earns the right to be ignored. Require a
# @Test-family annotation — or one of the DSL forms, which name a case in a
# string literal and so are self-evidently tests.
JVM = Language(
    name="jvm",
    style=BRACE,
    starts=(
        re.compile(r"^\s*(?:@\w[\w.]*(?:\([^)]*\))?\s*)*(?:\w+\s+)*fun\s+(?:`[^`]+`|\w+)\s*\("),
        re.compile(r"^\s*(?:public|private|protected|static|final|\s)*void\s+\w+\s*\([^;]*\)\s*\{"),
    ),
    self_evident=(
        re.compile(r"""^\s*(?:it|test|should|describe|context|given|when|then)\s*\(\s*['"]"""),
        re.compile(r"""^\s*['"].*['"]\s*(?:should|-)\s*\{"""),
    ),
    marker=re.compile(
        r"@(?:Test|ParameterizedTest|RepeatedTest|TestFactory|TestTemplate|"
        r"ValueSource|MethodSource|CsvSource|EnumSource)\b"
    ),
)

JS = Language(
    name="js",
    style=BRACE,
    starts=(
        re.compile(r"""^\s*(?:it|test)(?:\.\w+)*\s*\(\s*['"`]"""),
        re.compile(r"""^\s*(?:it|test)(?:\.\w+)*\s*\(\s*$"""),
    ),
)

PY = Language(
    name="python",
    style=INDENT,
    starts=(re.compile(r"^\s*(?:async\s+)?def\s+test\w*\s*\("),),
    line_comment=("#",),
    block_comment=(),
    quotes=('"', "'"),
)

GO = Language(
    name="go",
    style=BRACE,
    starts=(re.compile(r"^func\s+(?:Test|Benchmark|Fuzz|Example)\w*\s*\("),),
    quotes=('"', "`"),
)

RUST = Language(
    name="rust",
    style=BRACE,
    starts=(re.compile(r"^\s*(?:pub\s+)?(?:async\s+)?fn\s+\w+\s*\("),),
    marker=re.compile(r"#\[(?:\w+::)?(?:test|tokio::test|rstest)\b"),
    quotes=('"',),
)

LANGUAGES: dict[str, Language] = {
    ".kt": JVM, ".kts": JVM, ".java": JVM, ".scala": JVM, ".groovy": JVM,
    ".ts": JS, ".tsx": JS, ".js": JS, ".jsx": JS, ".mjs": JS, ".cjs": JS,
    ".py": PY,
    ".go": GO,
    ".rs": RUST,
}


# --- Assertion vocabulary ----------------------------------------------------
#
# Classification is per LINE, and the three patterns are tried in this order.
# Order is the whole trick: `expect(fn).not.toThrow()` contains `expect(`, so a
# discriminating-first pass would call it a real assertion. Weakest wins.

NO_THROW = re.compile(
    r"(?:"
    r"\bassertDoesNotThrow(?:Exactly)?\b|\bshouldNotThrow(?:Any|Exactly)?\b|"
    r"\bassertNoException\b|\bdoesNotThrowAnyException\b|"
    r"\.\s*not\s*\.\s*toThrow\w*|"
    r"\bassert_does_not_raise\b|\bdoes_not_raise\b|"
    r"\b(?:require|assert)\.NoError\b"
    r")"
)

EXISTENCE = re.compile(
    r"(?:"
    r"\bassertNotNull\b|\bassertIsNotNull\b|\bisNotNull\b|\bshouldNotBeNull\b|"
    r"\bnotNullValue\b|\btoBeDefined\b|\btoBeTruthy\b|\btoBeFalsy\b|"
    r"\.\s*not\s*\.\s*toBeNull\b|\btoBeInTheDocument\b|"
    r"\bassertIsNotNone\b|\bassertIsNone\b|\bis\s+not\s+None\b|"
    r"\b(?:require|assert)\.NotNil\b|\bassert_not_nil\b"
    r")"
)

ASSERTION = re.compile(
    r"(?:"
    # Call-shaped: assertEquals(, expect(, verify {, assert_eq!(, should(
    r"\b(?:assert|verify|expect|should|check)\w*\s*!?\s*[\(\{]|"
    # Library-qualified: require.Equal(, assert.True(
    r"\b(?:require|assert)\.\w+\s*\(|"
    # Go's idiom has no assertion library — a failure call IS the assertion
    r"\bt\.(?:Error|Errorf|Fatal|Fatalf)\s*\(|"
    # Statement-shaped: Python's bare `assert x == 1`, Rust's `assert!`
    r"^\s*assert\b(?!\s*\()|"
    # Matcher tails that carry the comparison
    r"\.\s*(?:toEqual|toBe|toStrictEqual|toMatch\w*|toContain\w*|"
    r"toHaveLength|toHaveBeenCalled\w*|toThrow\w*)\s*\("
    r")"
)

# A body with no calls at all is a placeholder or a pure fixture — not our business.
CALL = re.compile(r"\w\s*\(")


@dataclass
class Finding:
    path: str
    line: int
    name: str
    tier: str  # "FAIL" | "WARN"
    reason: str


@dataclass
class Report:
    findings: list[Finding] = field(default_factory=list)
    examined: int = 0
    unparsed: list[str] = field(default_factory=list)
    skipped_no_language: list[str] = field(default_factory=list)


# --- Git ---------------------------------------------------------------------


def run_git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def added_lines_by_file(base: str) -> dict[str, set[int]]:
    """Line numbers added or modified in `base..HEAD`, per file."""
    diff = run_git("diff", "--unified=0", "--no-color", f"{base}..HEAD")
    result: dict[str, set[int]] = {}
    current: str | None = None
    lineno = 0
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current = line[6:]
            result.setdefault(current, set())
            continue
        if line.startswith("+++ /dev/null"):
            current = None
            continue
        m = HUNK.match(line)
        if m:
            lineno = int(m.group(1))
            continue
        if current and line.startswith("+") and not line.startswith("+++"):
            result[current].add(lineno)
            lineno += 1
    return {p: lines for p, lines in result.items() if lines}


# --- Body extraction ---------------------------------------------------------


def strip_noise(line: str, lang: Language) -> str:
    """Remove string literals and comments so braces inside them don't count."""
    out: list[str] = []
    i = 0
    quote: str | None = None
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in lang.quotes:
            quote = ch
            i += 1
            continue
        if any(line.startswith(c, i) for c in lang.line_comment):
            break
        matched_block = False
        for opener, closer in lang.block_comment:
            if line.startswith(opener, i):
                end = line.find(closer, i + len(opener))
                if end == -1:
                    return "".join(out)
                i = end + len(closer)
                matched_block = True
                break
        if matched_block:
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def brace_body(lines: list[str], start: int, lang: Language) -> tuple[int, int] | None:
    """Return (first, last) 0-based line indices of the function body."""
    depth = 0
    opened = False
    for idx in range(start, len(lines)):
        clean = strip_noise(lines[idx], lang)
        for ch in clean:
            if ch == "{":
                depth += 1
                opened = True
            elif ch == "}":
                depth -= 1
                if opened and depth == 0:
                    return start, idx
        if opened and depth < 0:
            return None
    return None


def indent_body(lines: list[str], start: int) -> tuple[int, int]:
    base = len(lines[start]) - len(lines[start].lstrip())
    for idx in range(start + 1, len(lines)):
        stripped = lines[idx].strip()
        if not stripped or stripped.startswith("#"):
            continue
        if len(lines[idx]) - len(lines[idx].lstrip()) <= base:
            return start, idx - 1
    return start, len(lines) - 1


ANNOTATION_OR_COMMENT = re.compile(r"^\s*(?:@|#\[|//|/\*|\*|$)")


def starts_a_test(lines: list[str], idx: int, lang: Language) -> bool:
    """Whether line `idx` begins a test function.

    A `starts` match alone is not enough for languages that mark tests with an
    annotation: test classes are full of private fixture builders, and flagging
    those as assertionless tests is how a check earns the right to be ignored.
    Look at the declaration line and walk up through the annotations, comments
    and blank lines directly above it.
    """
    line = lines[idx]
    if any(p.search(line) for p in lang.self_evident):
        return True
    if not any(p.search(line) for p in lang.starts):
        return False
    if lang.marker is None:
        return True
    if lang.marker.search(line):
        return True
    for prev in range(idx - 1, -1, -1):
        candidate = lines[prev]
        if not ANNOTATION_OR_COMMENT.match(candidate):
            return False
        if lang.marker.search(candidate):
            return True
    return False


def function_name(line: str) -> str:
    m = re.search(r"(?:fun|def|func|void|fn)\s+(`[^`]+`|\w+)", line)
    if m:
        return m.group(1).strip("`")
    m = re.search(r"""['"`]([^'"`]{1,80})['"`]""", line)
    return m.group(1) if m else line.strip()[:60]


# --- Classification ----------------------------------------------------------


def classify(body_lines: list[str]) -> tuple[str, str] | None:
    """Return (tier, reason) when the body is weak, else None.

    Each line gets at most one tier, weakest pattern first. A body is weak only
    when NO line reached the discriminating tier.
    """
    no_throw = existence = False
    for line in body_lines:
        if NO_THROW.search(line):
            no_throw = True
        elif EXISTENCE.search(line):
            existence = True
        elif ASSERTION.search(line):
            return None

    if no_throw:
        return "FAIL", "only asserts that nothing was thrown"
    if existence:
        return "WARN", "only asserts existence (not-null / defined / truthy)"
    if any(CALL.search(line) for line in body_lines):
        return "FAIL", "calls production code but asserts nothing"
    return None


def examine(path: str, added: set[int], report: Report) -> None:
    lang = LANGUAGES.get(Path(path).suffix)
    if lang is None:
        report.skipped_no_language.append(path)
        return
    try:
        lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        report.unparsed.append(path)
        return

    found_any = False
    for idx, line in enumerate(lines):
        if not starts_a_test(lines, idx, lang):
            continue
        span = (
            indent_body(lines, idx)
            if lang.style == INDENT
            else brace_body(lines, idx, lang)
        )
        if span is None:
            continue
        found_any = True
        first, last = span
        touched = any(first + 1 <= n <= last + 1 for n in added)
        if not touched:
            continue
        report.examined += 1
        body = [strip_noise(l, lang) for l in lines[first : last + 1]]
        verdict = classify(body)
        if verdict:
            tier, reason = verdict
            report.findings.append(
                Finding(path, first + 1, function_name(line), tier, reason)
            )
    if not found_any:
        report.unparsed.append(path)


# --- Output ------------------------------------------------------------------


def write_report(report: Report, output: Path | None, result: str) -> None:
    fails = [f for f in report.findings if f.tier == "FAIL"]
    warns = [f for f in report.findings if f.tier == "WARN"]

    lines = [
        "# Test Assertion Check",
        "",
        f"**Status**: {result}",
        f"**Test functions examined**: {report.examined}",
        f"**Blocking findings**: {len(fails)}",
        f"**Advisory findings**: {len(warns)}",
        "",
    ]
    if fails:
        lines += ["## Asserts nothing (blocking)", ""]
        lines += [f"- `{f.path}:{f.line}` — `{f.name}` — {f.reason}" for f in fails]
        lines += [
            "",
            "These tests pass whether the code under test works or is replaced by a",
            "stub. Add an assertion on the observable outcome, or delete the test.",
            "",
        ]
    if warns:
        lines += ["## Asserts only existence (advisory)", ""]
        lines += [f"- `{f.path}:{f.line}` — `{f.name}` — {f.reason}" for f in warns]
        lines += [""]
    if report.unparsed:
        lines += [
            "## Not analysed — no test functions delimited",
            "",
            "The check abstains rather than guessing. These files were not judged:",
            "",
        ]
        lines += [f"- `{p}`" for p in report.unparsed]
        lines += [""]
    if report.skipped_no_language:
        lines += ["## Not analysed — language not in the table", ""]
        lines += [f"- `{p}`" for p in report.skipped_no_language]
        lines += [""]
    if not report.findings:
        lines += ["No touched test asserts nothing.", ""]

    text = "\n".join(lines)
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(text, encoding="utf-8")
    else:
        print(text)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, help="commit to diff against")
    parser.add_argument("--output", help="path to write the markdown report")
    args = parser.parse_args()

    try:
        added = added_lines_by_file(args.base)
    except (RuntimeError, FileNotFoundError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(2)

    report = Report()
    for path, lines in sorted(added.items()):
        if is_test_path(path):
            examine(path, lines, report)

    fails = [f for f in report.findings if f.tier == "FAIL"]
    result = "FAIL" if fails else "CLEAN"
    write_report(report, Path(args.output) if args.output else None, result)

    print(
        f"Test assertions: {result} "
        f"({report.examined} examined, {len(fails)} blocking, "
        f"{len(report.findings) - len(fails)} advisory)"
    )
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
