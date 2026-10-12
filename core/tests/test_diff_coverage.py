#!/usr/bin/env python3
"""Unit tests for diff-coverage.py JaCoCo classification.

Focus: non-executable diff lines (annotation entries, `enum class X {` and other
bare declaration headers) must NOT be reported as uncovered. JaCoCo emits no
<line> for them, so they carry no bytecode and cannot be "uncovered".

Models the the original false positive:
  - ApiError.kt:15      -> `JsonSubTypes.Type(...)` annotation entry
  - WidgetStatus.kt:3     -> `enum class WidgetStatus {`
both of which `is_meaningful` flags as meaningful, but JaCoCo never tracks.

Run directly:  python3 core/tests/test_diff_coverage.py      (from the cg-core checkout)
Exit 0 = all pass, 1 = failure.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "stacks" / "kotlin-backend" / ".claude" / "scripts" / "diff-coverage.py"


def load_module():
    spec = importlib.util.spec_from_file_location("diff_coverage", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["diff_coverage"] = mod  # dataclass needs the module registered
    spec.loader.exec_module(mod)
    return mod


dc = load_module()

PASS = 0
FAIL = 0


def check(name: str, condition: bool, detail: str = "") -> None:
    global PASS, FAIL
    if condition:
        print(f"PASS  {name}")
        PASS += 1
    else:
        print(f"FAIL  {name}  {detail}")
        FAIL += 1


# A JaCoCo report shaped like the the original run:
#   - WidgetStatus.kt: the enum's <clinit>/synthetic methods attribute to the
#     first constant line (4), fully covered. NO <line> for the `enum class` header (3).
#   - Widget.kt: one covered executable line (11) and one genuinely
#     uncovered executable line (10) -- the regression guard.
#   - ApiError.kt: a pure sealed interface with annotations -> JaCoCo emits
#     no <line> at all, so it is absent from the report entirely.
JACOCO_XML = """<?xml version="1.0" encoding="UTF-8"?>
<report name="test">
  <package name="com/example/app/core/widget/domain">
    <sourcefile name="WidgetStatus.kt">
      <line nr="4" mi="0" ci="37" mb="0" cb="0"/>
    </sourcefile>
    <sourcefile name="Widget.kt">
      <line nr="10" mi="5" ci="0" mb="0" cb="0"/>
      <line nr="11" mi="0" ci="4" mb="0" cb="0"/>
    </sourcefile>
  </package>
</report>
"""

# Added/modified meaningful lines from the diff (path -> {line: text}).
ADDED = {
    "src/main/kotlin/com/example/app/core/widget/domain/WidgetStatus.kt": {
        3: "enum class WidgetStatus {",
    },
    "src/main/kotlin/com/example/app/core/api/ApiError.kt": {
        15: '    JsonSubTypes.Type(value = WidgetLimitDetails::class, name = "WIDGET_LIMIT"),',
    },
    "src/main/kotlin/com/example/app/core/widget/domain/Widget.kt": {
        10: "        val violations = violationsFor(order)",
        11: "        return violations.isEmpty()",
    },
}


def run() -> None:
    import tempfile

    with tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False) as f:
        f.write(JACOCO_XML)
        xml_path = Path(f.name)

    tracked = dc.parse_jacoco(xml_path)
    xml_path.unlink()

    # parse_jacoco now carries (mi, ci) per tracked line, and only tracked lines exist.
    lt = dc.match_jacoco_path(
        "src/main/kotlin/com/example/app/core/widget/domain/WidgetStatus.kt",
        tracked,
    )
    check("parse: enum constant line tracked with instructions", lt.get(4) == (0, 37), f"got {lt.get(4)}")
    check("parse: enum class header line absent (non-executable)", 3 not in lt, f"keys={sorted(lt)}")

    uncovered, executable, covered, non_exec = dc.evaluate_jacoco(ADDED, tracked)

    joined = "\n".join(uncovered)

    # The two the original false positives must NOT be reported.
    check(
        "enum class header not flagged uncovered",
        "WidgetStatus.kt:3" not in joined,
        f"uncovered={uncovered}",
    )
    check(
        "annotation entry not flagged uncovered",
        "ApiError.kt:15" not in joined,
        f"uncovered={uncovered}",
    )

    # Regression guard: a genuinely uncovered executable line is still caught.
    check(
        "genuinely uncovered executable line still flagged",
        any("Widget.kt:10" in u for u in uncovered),
        f"uncovered={uncovered}",
    )

    # Counts: 2 executable (Widget 10 + 11), 1 covered (11),
    # 2 non-executable excluded (enum header + annotation entry).
    check("executable count == 2", executable == 2, f"got {executable}")
    check("covered count == 1", covered == 1, f"got {covered}")
    check("non-executable excluded == 2", non_exec == 2, f"got {non_exec}")
    check("exactly one uncovered", len(uncovered) == 1, f"got {uncovered}")

    # End-to-end shape: with only the two non-executable lines added, verdict is CLEAN.
    clean_added = {
        k: v for k, v in ADDED.items() if "Widget.kt" not in k
    }
    unc2, _, _, nonexec2 = dc.evaluate_jacoco(clean_added, tracked)
    check("the original repro: only non-exec lines -> CLEAN", unc2 == [], f"uncovered={unc2}")
    check("the original repro: both lines excluded as non-exec", nonexec2 == 2, f"got {nonexec2}")


def run_parse_error() -> None:
    """main() must NOT silently pass when a JaCoCo report exists but is unparseable.
    The fix's refactor briefly made this path set tracked_map={} → every line
    counted 'non-executable' → CLEAN. A gate must fail loud on an unreadable report.
    """
    import tempfile

    bad = Path(tempfile.mktemp(suffix=".xml"))
    bad.write_text("<report><sourcefile name='Foo.kt'><line nr=", encoding="utf-8")  # truncated
    out = Path(tempfile.mktemp(suffix=".md"))
    orig_find, orig_added, orig_argv = dc.find_jacoco_report, dc.get_added_lines, sys.argv[:]
    dc.find_jacoco_report = lambda: bad
    dc.get_added_lines = lambda base: {"src/main/kotlin/Foo.kt": {10: "doThing()"}}
    sys.argv[:] = ["diff-coverage.py", "--base", "BASE", "--output", str(out)]
    code = 0
    try:
        dc.main()
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 1
    finally:
        dc.find_jacoco_report, dc.get_added_lines = orig_find, orig_added
        sys.argv[:] = orig_argv
        bad.unlink(missing_ok=True)
        out.unlink(missing_ok=True)
    check("unparseable JaCoCo report -> non-zero exit, no silent CLEAN", code == 2, f"exit={code}")


def run_stale_report() -> None:
    """A failed test run leaves the previous report behind. Judged by it, the diff gets a
    verdict about code that is gone: the check must refuse (exit 2), not FAIL or pass."""
    import os
    import subprocess
    import tempfile

    repo = Path(tempfile.mkdtemp())
    git = lambda *a: subprocess.check_output(["git", "-C", str(repo), *a], text=True).strip()
    git("init", "-q")
    git("config", "user.email", "t@t"); git("config", "user.name", "t")
    src = repo / "src/main/kotlin/Foo.kt"
    src.parent.mkdir(parents=True)
    src.write_text("class Foo\n", encoding="utf-8")
    git("add", "."); git("commit", "-qm", "base")
    base = git("rev-parse", "HEAD")
    src.write_text("class Foo {\n    fun bar() = 1\n}\n", encoding="utf-8")
    git("add", "."); git("commit", "-qm", "change")
    changed_at = int(git("log", "-1", "--format=%ct"))
    report = repo / "jacoco.xml"
    report.write_text(
        '<report name="t"><package name=""><sourcefile name="Foo.kt">'
        '<line nr="2" mi="0" ci="3" mb="0" cb="0"/></sourcefile></package></report>',
        encoding="utf-8",
    )

    def verdict(mtime: int) -> int:
        os.utime(report, (mtime, mtime))
        out = repo / "out.md"
        orig_find, orig_argv, cwd = dc.find_jacoco_report, sys.argv[:], os.getcwd()
        dc.find_jacoco_report = lambda: report
        sys.argv[:] = ["diff-coverage.py", "--base", base, "--output", str(out)]
        os.chdir(repo)
        try:
            dc.main()
        except SystemExit as e:
            return e.code if isinstance(e.code, int) else 1
        finally:
            os.chdir(cwd)
            dc.find_jacoco_report, sys.argv[:] = orig_find, orig_argv
        return 0

    check("report older than the last production commit -> exit 2", verdict(changed_at - 100) == 2)
    check("report newer than the last production commit -> judged", verdict(changed_at + 100) != 2)


if __name__ == "__main__":
    run()
    run_parse_error()
    run_stale_report()
    print(f"\nResults: {PASS} passed, {FAIL} failed")
    sys.exit(1 if FAIL else 0)
