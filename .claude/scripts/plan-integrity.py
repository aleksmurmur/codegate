#!/usr/bin/env python3
"""Mechanical plan integrity check.

Verifies that claims in a PLAN.md refer to things that actually exist in the
codebase. This is a deterministic check — no LLM reasoning.

What it verifies:
- Checklist items: paths to modify/delete must exist; paths to create must NOT exist.
- Migration version numbers must not collide with existing migrations.
- Symbols (backtick-wrapped class/method names) should appear somewhere in the repo.

What it does NOT verify:
- Pattern consistency with CODEBASE_CONTEXT.md (that's reasoning — handled elsewhere).
- Whether the plan is a good idea.
- Whether the scope is right.

Usage:
    plan-integrity.py <path-to-PLAN.md>

Exit codes:
    0 — CLEAN (no mirages; warnings may exist but are not blocking)
    1 — blocking failure, one of:
        MIRAGES_FOUND — plan cites paths/symbols that don't exist
        PARSE_FAILED  — no `## Checklist` heading, or heading present but no items parsed
    2 — error reading inputs

Output:
    Writes `integrity-report.md` alongside PLAN.md.
    Prints a one-line verdict + counts to stdout.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

CREATE_VERBS = {"create", "add", "new"}
MODIFY_VERBS = {"modify", "update", "change", "edit", "extend"}
DELETE_VERBS = {"delete", "remove"}

CHECKLIST_LINE = re.compile(
    r"^\s*[-*]?\s*\[[ xX]\]\s*\d+\.?\s+(\w+)\s+`?(\S+?\.\w+)`?(?:\s|$)"
)
MIGRATION_VERSION = re.compile(r"V(\d+)__")
LIQUIBASE_SIGNALS = re.compile(
    r"(^|/)db/changelog/|changelog-master\.(xml|ya?ml|json|sql)$"
)
SYMBOL_IN_BACKTICKS = re.compile(
    r"`([A-Z][A-Za-z0-9_]+(?:\.[a-zA-Z_][A-Za-z0-9_]*)?(?:\(\))?)`"
)


def read_plan(path: Path) -> str:
    if not path.exists():
        print(f"error: PLAN file not found: {path}", file=sys.stderr)
        sys.exit(2)
    return path.read_text(encoding="utf-8")


def extract_checklist(text: str):
    """Return (items, had_header).

    items: list of (verb_lower, path) tuples from lines inside the Checklist section.
    had_header: True if a `## Checklist` heading (any level) appeared in the plan.
    """
    items: list[tuple[str, str]] = []
    had_header = False
    in_checklist = False
    for line in text.splitlines():
        if re.match(r"^#+\s+Checklist", line, re.IGNORECASE):
            in_checklist = True
            had_header = True
            continue
        if in_checklist and line.startswith("#"):
            in_checklist = False
            continue
        if not in_checklist:
            continue
        m = CHECKLIST_LINE.match(line)
        if m:
            items.append((m.group(1).lower(), m.group(2)))
    return items, had_header


def git_ls_files() -> set[str]:
    try:
        out = subprocess.check_output(
            ["git", "ls-files"], text=True, stderr=subprocess.DEVNULL
        )
        return set(out.splitlines())
    except (subprocess.CalledProcessError, FileNotFoundError):
        return set()


def detect_migration_tool(tracked: set[str]) -> str:
    """Identify which migration tool the repo uses from tracked files.

    Returns one of: "flyway", "liquibase", "both", "none".
    """
    has_flyway = any(MIGRATION_VERSION.search(Path(p).name) for p in tracked)
    has_liquibase = any(LIQUIBASE_SIGNALS.search(p) for p in tracked)
    if has_flyway and has_liquibase:
        return "both"
    if has_flyway:
        return "flyway"
    if has_liquibase:
        return "liquibase"
    return "none"


def check_path(verb: str, path: str, tracked: set[str]) -> str | None:
    exists = Path(path).exists() or path in tracked
    if verb in CREATE_VERBS and exists:
        return (
            f"plan says {verb.upper()} but file already exists: {path}"
            "  (use MODIFY, or correct the path)"
        )
    if (verb in MODIFY_VERBS or verb in DELETE_VERBS) and not exists:
        return f"plan says {verb.upper()} but file not found: {path}"
    return None


def check_migration_collisions(items, tracked: set[str]) -> list[str]:
    mirages: list[str] = []
    for verb, path in items:
        if verb not in CREATE_VERBS:
            continue
        m = MIGRATION_VERSION.search(Path(path).name)
        if not m:
            continue
        version = m.group(1)
        for tracked_path in tracked:
            if tracked_path == path:
                continue
            other = MIGRATION_VERSION.search(Path(tracked_path).name)
            if other and other.group(1) == version:
                mirages.append(
                    f"migration V{version} already exists: {tracked_path} — use next free version"
                )
    return mirages


def grep_symbol(symbol: str) -> bool:
    """Return True if `git grep` finds the symbol anywhere in tracked files."""
    try:
        subprocess.check_output(
            ["git", "grep", "-q", "--", symbol], stderr=subprocess.DEVNULL
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def check_symbols(text: str) -> list[str]:
    """Return warnings for backtick-wrapped symbols not found in the repo."""
    warnings: list[str] = []
    seen: set[str] = set()
    for m in SYMBOL_IN_BACKTICKS.finditer(text):
        raw = m.group(1)
        sym = raw.rstrip("()")
        if "." in sym:
            _, sym = sym.rsplit(".", 1)
        if sym in seen or len(sym) < 3:
            continue
        seen.add(sym)
        if not grep_symbol(sym):
            warnings.append(f"symbol not found in repo: `{raw}`")
    return warnings


def write_report(
    report_path: Path, verdict: str, tool: str, verified, mirages, warnings
) -> None:
    lines = [
        "# Plan Integrity Report",
        "",
        f"**Status**: {verdict}",
        f"**Migration tool**: {tool}",
        "",
    ]
    if verified:
        lines.append(f"## Verified ({len(verified)} items)")
        lines.extend(f"- OK: {v}" for v in verified)
        lines.append("")
    if mirages:
        lines.append(f"## Mirages ({len(mirages)} — blocking)")
        lines.extend(f"- MIRAGE: {m}" for m in mirages)
        lines.append("")
    if warnings:
        lines.append(f"## Warnings ({len(warnings)} — non-blocking)")
        lines.append("Symbols mentioned in the plan that were not found in the repo.")
        lines.append("May be intentional (new symbol being introduced) or may be a typo.")
        lines.append("")
        lines.extend(f"- WARN: {w}" for w in warnings)
        lines.append("")
    report_path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: plan-integrity.py <path-to-PLAN.md>", file=sys.stderr)
        sys.exit(2)

    plan_path = Path(sys.argv[1])
    text = read_plan(plan_path)
    items, had_header = extract_checklist(text)

    tracked = git_ls_files()
    tool = detect_migration_tool(tracked)
    report_path = plan_path.parent / "integrity-report.md"

    if not had_header:
        print("FAIL: no '## Checklist' heading found in plan")
        write_report(
            report_path, "PARSE_FAILED", tool, [], [],
            ["no '## Checklist' heading — every plan must have a Checklist section"],
        )
        sys.exit(1)

    if not items:
        print("FAIL: Checklist section has no parseable items")
        write_report(
            report_path, "PARSE_FAILED", tool, [], [],
            [
                "Checklist heading found but no items parsed.",
                "Expected: `[ ] N. Verb path.ext — description`",
                "Optional `-` or `*` bullet prefix and period after N are accepted.",
            ],
        )
        sys.exit(1)

    mirages: list[str] = []
    verified: list[str] = []

    for verb, path in items:
        err = check_path(verb, path, tracked)
        if err:
            mirages.append(err)
        else:
            verified.append(f"{verb} {path}")

    if tool in ("flyway", "both"):
        mirages.extend(check_migration_collisions(items, tracked))
    warnings = check_symbols(text)

    verdict = "MIRAGES_FOUND" if mirages else "CLEAN"
    write_report(report_path, verdict, tool, verified, mirages, warnings)

    print(f"Plan integrity: {verdict}")
    print(f"  Migration tool: {tool}")
    print(f"  Verified: {len(verified)}")
    print(f"  Mirages:  {len(mirages)}")
    print(f"  Warnings: {len(warnings)}")
    print(f"  Report:   {report_path}")

    sys.exit(1 if mirages else 0)


if __name__ == "__main__":
    main()
