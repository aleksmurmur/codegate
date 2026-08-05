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
from dataclasses import dataclass, field, replace
from pathlib import Path

# --- Which files are tests ---------------------------------------------------

# Tooling, vendored code and build output. `.claude/` matters most: codegate
# ships its own deliberately-weak fixtures under a `tests/` path, and reporting
# those on every run would bury the project's real findings.
EXCLUDED_PREFIXES = (
    ".ai/", ".claude/", ".git/", ".github/", ".idea/",
    "build/", "dist/", "out/", "target/", "vendor/", "node_modules/",
)

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
    if any(path.startswith(prefix) for prefix in EXCLUDED_PREFIXES):
        return False
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
    # Delimiters whose literal may span lines (Kotlin/Python triple quotes, JS
    # and Go backticks). Carried across lines like a block comment. Ordinary
    # quotes are deliberately NOT carried: a single unbalanced one would eat the
    # rest of the file, which is worse than the brace it was meant to hide.
    multiline_quotes: tuple[str, ...] = ()
    # Kotlin and Scala allow `/* /* */ */`; Java and Groovy do not.
    nested_block_comments: bool = False


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
    multiline_quotes=('"""',),
)

# Kotlin and Scala nest block comments; Java and Groovy do not, and pretending
# they do would swallow every line after the first `*/`.
KOTLIN = replace(JVM, name="kotlin", nested_block_comments=True)

JS = Language(
    name="js",
    style=BRACE,
    starts=(
        re.compile(r"""^\s*(?:it|test)(?:\.\w+)*\s*\(\s*['"`]"""),
        re.compile(r"""^\s*(?:it|test)(?:\.\w+)*\s*\(\s*$"""),
    ),
    multiline_quotes=("`",),
)

PY = Language(
    name="python",
    style=INDENT,
    starts=(re.compile(r"^\s*(?:async\s+)?def\s+test\w*\s*\("),),
    line_comment=("#",),
    block_comment=(),
    quotes=('"', "'"),
    multiline_quotes=('"""', "'''"),
)

GO = Language(
    name="go",
    style=BRACE,
    starts=(re.compile(r"^func\s+(?:Test|Benchmark|Fuzz|Example)\w*\s*\("),),
    quotes=('"', "`"),
    multiline_quotes=("`",),
)

RUST = Language(
    name="rust",
    style=BRACE,
    starts=(re.compile(r"^\s*(?:pub\s+)?(?:async\s+)?fn\s+\w+\s*\("),),
    marker=re.compile(r"#\[(?:\w+::)?(?:test|tokio::test|rstest)\b"),
    quotes=('"',),
)

LANGUAGES: dict[str, Language] = {
    ".kt": KOTLIN, ".kts": KOTLIN, ".scala": KOTLIN,
    ".java": JVM, ".groovy": JVM,
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
    # Call-shaped, with an optional generic parameter list: assertEquals(,
    # expect(, verify {, assert_eq!(, and Kotlin's `assertThrows<T> { }` /
    # `assertFailsWith<T> { }` / `shouldThrow<T> { }` — the generics are why a
    # naive `\w*\s*[\(\{]` misses the most common negative-path assertion.
    r"\b(?:assert|verify|expect|should|check)\w*\s*(?:<[^>]*>)?\s*!?\s*[\(\{]|"
    # Spring MockMvc: the assertion is a chained `andExpect`, not a bare
    # `expect`. Overwhelmingly the dominant idiom in JVM web-layer suites.
    r"\bandExpect(?:All)?\s*[\(\{]|"
    # Library-qualified: require.Equal(, assert.True(
    r"\b(?:require|assert)\.\w+\s*\(|"
    # Go's idiom has no assertion library — a failure call IS the assertion
    r"\bt\.(?:Error|Errorf|Fatal|Fatalf)\s*\(|"
    # pytest's context-manager form
    r"\bpytest\.raises\s*\(|"
    # Assertion-shaped helper names: `awaitStatus(...)`, `expectStatus(...)`,
    # `verifyBalance(...)`, `ensureRefunded(...)`. Helpers in a base class or a
    # shared module cannot be followed, and this check blocks the gate — so when
    # a call names itself an assertion, believe it. Over-matching costs a missed
    # weak test; under-matching blocks correct code, which is worse.
    r"\b(?:await|ensure|require|verify|expect|assert|check|should)[A-Z]\w*\s*\(|"
    # Statement-shaped: Python's bare `assert x == 1`, Rust's `assert!`
    r"^\s*assert\b(?!\s*\()|"
    # Matcher tails that carry the comparison
    r"\.\s*(?:toEqual|toBe|toStrictEqual|toMatch\w*|toContain\w*|"
    r"toHaveLength|toHaveBeenCalled\w*|toThrow\w*|"
    r"isEqualTo|isTrue|isFalse|hasSize|containsExactly\w*)\s*\("
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
    # Decode as UTF-8 explicitly. `text=True` alone uses the locale codec, and on
    # a Windows box with a non-UTF-8 code page any non-ASCII byte in a diff kills
    # subprocess's reader thread; stdout then comes back None and the caller dies
    # with an unhandled error — exit 1, which the flow reads as a real FAIL.
    result = subprocess.run(
        ["git", *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {(result.stderr or '').strip()}")
    if result.stdout is None:
        raise RuntimeError(f"git {' '.join(args)} produced no readable output")
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


# Carried state for a region that may span lines: (opener, closer, depth).
# Depth is only ever > 1 for languages whose block comments nest.
Region = tuple[str, str, int]


def strip_noise(
    line: str, lang: Language, block: Region | None = None
) -> tuple[str, Region | None]:
    """Remove string literals and comments so braces inside them don't count.

    `block` is the multi-line region still open when the previous line ended —
    a block comment or a triple-quoted / backtick string — and the return carries
    it forward. Without that state, a `{` or `}` on an interior line of such a
    region is counted as real code, which truncates the extracted body and
    reports a test that does assert as one that does not.

    Ordinary single- and double-quoted strings are line-scoped on purpose: one
    unbalanced quote would otherwise swallow the rest of the file, which is a
    worse failure than the brace it was meant to hide.
    """
    out: list[str] = []
    i = 0
    quote: str | None = None
    while i < len(line):
        if block is not None:
            opener, closer, depth = block
            close_at = line.find(closer, i)
            open_at = (
                line.find(opener, i)
                if lang.nested_block_comments and opener != closer
                else -1
            )
            if close_at == -1 and open_at == -1:
                return "".join(out), block
            if open_at != -1 and (close_at == -1 or open_at < close_at):
                block = (opener, closer, depth + 1)
                i = open_at + len(opener)
                continue
            i = close_at + len(closer)
            block = None if depth == 1 else (opener, closer, depth - 1)
            continue

        ch = line[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue

        # Multi-line-capable literals first: `"""` also starts with `"`.
        entered = False
        for q in lang.multiline_quotes:
            if line.startswith(q, i):
                block = (q, q, 1)
                i += len(q)
                entered = True
                break
        if entered:
            continue

        if ch in lang.quotes:
            quote = ch
            i += 1
            continue
        if any(line.startswith(c, i) for c in lang.line_comment):
            break

        for opener, closer in lang.block_comment:
            if line.startswith(opener, i):
                block = (opener, closer, 1)
                i += len(opener)
                entered = True
                break
        if entered:
            continue

        out.append(ch)
        i += 1
    return "".join(out), block


def clean_lines(lines: list[str], lang: Language) -> list[str]:
    """Strip strings and comments file-wide, carrying multi-line region state."""
    cleaned: list[str] = []
    block: Region | None = None
    for line in lines:
        text, block = strip_noise(line, lang, block)
        cleaned.append(text)
    return cleaned


def brace_body(cleaned: list[str], start: int) -> tuple[int, int] | None:
    """Return (first, last) 0-based line indices of the function body.

    Operates on comment- and string-free lines from [clean_lines].
    """
    depth = 0
    opened = False
    for idx in range(start, len(cleaned)):
        for ch in cleaned[idx]:
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


CALLEE = re.compile(r"\b([A-Za-z_]\w*)\s*\(")
HELPER_DEPTH = 2


def scan_tiers(body_lines: list[str]) -> tuple[bool, bool, bool]:
    """(has_discriminating, has_no_throw, has_existence) over one body."""
    no_throw = existence = False
    for line in body_lines:
        if NO_THROW.search(line):
            no_throw = True
        elif EXISTENCE.search(line):
            existence = True
        elif ASSERTION.search(line):
            return True, no_throw, existence
    return False, no_throw, existence


def classify(
    body_lines: list[str],
    helpers: dict[str, list[str]] | None = None,
    depth: int = HELPER_DEPTH,
    seen: set[str] | None = None,
) -> tuple[str, str] | None:
    """Return (tier, reason) when the body is weak, else None.

    Each line gets at most one tier, weakest pattern first; a body is weak only
    when no line reached the discriminating tier.

    Tests routinely delegate their assertion to a helper in the same file —
    `postExecutorPayment(..., expectStatus = 409)` whose body does the
    `andExpect`. Reporting those as assertionless is the single largest source
    of false positives, so calls are followed into same-file functions, bounded
    by depth and a visited set. Cross-file helpers remain out of reach; that is
    a known limit, not something to guess about.
    """
    discriminating, no_throw, existence = scan_tiers(body_lines)
    if discriminating:
        return None

    if helpers and depth > 0:
        seen = set() if seen is None else seen
        for line in body_lines:
            for name in CALLEE.findall(line):
                if name in seen or name not in helpers:
                    continue
                seen.add(name)
                if classify(helpers[name], helpers, depth - 1, seen) is None:
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

    cleaned = clean_lines(lines, lang)

    def body_of(start: int) -> tuple[int, int] | None:
        return (
            indent_body(lines, start)
            if lang.style == INDENT
            else brace_body(cleaned, start)
        )

    def body_lines(span: tuple[int, int]) -> list[str]:
        """Body text with the declaration's own header removed.

        Two things depend on getting this exactly right. A backtick-quoted
        Kotlin test name is stripped as a string literal, leaving `fun (` on the
        declaration line — which matches "makes a call" and turns an empty
        @Disabled stub into a finding. And an expression-bodied test
        (`fun x() = assertDoesNotThrow { ... }`) carries its only assertion on
        that same line, so cutting at the opening brace would hide it and
        mislabel a correct finding.

        Cut after the parameter list's closing paren, and keep the remainder.
        """
        first, last = span
        head = cleaned[first]
        paren = head.find(")")
        return ([head[paren + 1 :]] if paren != -1 else []) + cleaned[first + 1 : last + 1]

    # Every declaration in the file, test or not — tests delegate their
    # assertions to same-file helpers and those calls have to be followed.
    helpers: dict[str, list[str]] = {}
    for idx, line in enumerate(lines):
        if not any(p.search(line) for p in lang.starts):
            continue
        span = body_of(idx)
        if span is not None:
            helpers.setdefault(function_name(line), body_lines(span))

    found_any = False
    for idx, line in enumerate(lines):
        if not starts_a_test(lines, idx, lang):
            continue
        span = body_of(idx)
        if span is None:
            continue
        found_any = True
        first, last = span
        touched = any(first + 1 <= n <= last + 1 for n in added)
        if not touched:
            continue
        report.examined += 1
        verdict = classify(body_lines(span), helpers)
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
