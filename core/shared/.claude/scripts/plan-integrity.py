#!/usr/bin/env python3
"""Mechanical plan integrity check.

Verifies that claims in a PLAN.md refer to things that actually exist in the
codebase. This is a deterministic check — no LLM reasoning.

What it verifies:
- Checklist items: paths to modify/delete must exist; paths to create must NOT exist.
- Migration version numbers must not collide with existing migrations.
- Symbols (backtick-wrapped class/method names) should appear somewhere in the repo.
- Acceptance Criteria section exists with at least 3 items.
- Commit Plan section exists and references every checklist item exactly once.
- Design Notes section presence (soft warning).
- Security ACs declared when sensitive markers appear in plan text (soft warning).

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

CREATE_VERBS = {"create"}
MODIFY_VERBS = {"modify"}
DELETE_VERBS = {"delete"}

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
ACCEPTANCE_HEADING = re.compile(r"^#+\s+Acceptance\s+Criteria\s*$", re.IGNORECASE)
COMMIT_PLAN_HEADING = re.compile(r"^#+\s+Commit\s+Plan\s*$", re.IGNORECASE)
DESIGN_NOTES_HEADING = re.compile(r"^#+\s+Design\s+Notes\s*$", re.IGNORECASE)
AC_ITEM = re.compile(r"^\s*(?:\d+\.|\*|-)\s+\S")
ITEMS_REF = re.compile(r"\bitems\s+(\d[\d,\s]*?)(?:\s*\(|\s*$)", re.IGNORECASE)
SECURITY_TRIGGER = re.compile(
    r"\b(auth|login|password|token|secret|payment|api[ -]?key|file upload|"
    r"user input|PII|email address|phone number|SSN|file path.*from user|"
    r"outbound HTTP|raw SQL)\b",
    re.IGNORECASE,
)
SECURITY_AC_LINE = re.compile(
    r"^\s*(?:\d+\.|\*|-)?\s*\**\s*Security\s*:", re.IGNORECASE
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


def extract_section_lines(text: str, heading_regex) -> list[str]:
    """Lines inside the section identified by heading_regex, skipping fenced blocks."""
    lines: list[str] = []
    in_section = False
    in_fence = False
    for line in text.splitlines():
        if heading_regex.match(line):
            in_section = True
            continue
        if in_section and line.startswith("#"):
            break
        if not in_section:
            continue
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        lines.append(line)
    return lines


def validate_acceptance_criteria(text: str) -> list[str]:
    if not any(ACCEPTANCE_HEADING.match(ln) for ln in text.splitlines()):
        return [
            "missing 'Acceptance Criteria' section — every plan must declare 3-5 observable behaviors"
        ]
    section = extract_section_lines(text, ACCEPTANCE_HEADING)
    item_count = sum(1 for ln in section if AC_ITEM.match(ln))
    if item_count < 3:
        return [f"Acceptance Criteria has {item_count} items — at least 3 required"]
    return []


def validate_commit_plan(text: str, checklist_count: int) -> list[str]:
    if not any(COMMIT_PLAN_HEADING.match(ln) for ln in text.splitlines()):
        return [
            "missing 'Commit Plan' section — every plan must list expected commits with items mapping"
        ]
    section = extract_section_lines(text, COMMIT_PLAN_HEADING)
    items_per_commit: list[list[int]] = []
    for ln in section:
        m = ITEMS_REF.search(ln)
        if not m:
            continue
        try:
            nums = [int(x.strip()) for x in m.group(1).split(",") if x.strip()]
        except ValueError:
            continue
        if nums:
            items_per_commit.append(nums)

    if not items_per_commit:
        return ["Commit Plan section has no parseable 'items N, M, ...' references"]

    coverage: dict[int, int] = {}
    for nums in items_per_commit:
        for n in nums:
            coverage[n] = coverage.get(n, 0) + 1

    expected = set(range(1, checklist_count + 1))
    listed = set(coverage.keys())
    mirages: list[str] = []

    missing = sorted(expected - listed)
    if missing:
        mirages.append(f"Commit Plan misses checklist items: {missing}")

    extra = sorted(listed - expected)
    if extra:
        mirages.append(f"Commit Plan references items not in the checklist: {extra}")

    duplicated = sorted(n for n, c in coverage.items() if c > 1)
    if duplicated:
        mirages.append(
            f"Commit Plan references items in multiple commits (must be exactly one): {duplicated}"
        )
    return mirages


def check_design_notes(text: str) -> list[str]:
    """Return a soft warning if the plan lacks a Design Notes section.

    The script does not know the task type, so it can't say "feature/refactor
    must have one" — instead the warning hints that feature and refactor plans
    require it, and bugfix/migration plans should include it for non-trivial
    changes.
    """
    if any(DESIGN_NOTES_HEADING.match(ln) for ln in text.splitlines()):
        return []
    return [
        "no 'Design Notes' section — required for feature and refactor plans, "
        "recommended for non-trivial bugfix or migration plans"
    ]


def check_security_acs(text: str) -> list[str]:
    """Return a soft warning if the plan triggers security markers but
    declares no Security AC.
    """
    if not SECURITY_TRIGGER.search(text):
        return []
    section = extract_section_lines(text, ACCEPTANCE_HEADING)
    if any(SECURITY_AC_LINE.search(ln) for ln in section):
        return []
    return [
        "security-sensitive markers found in plan text, but Acceptance Criteria "
        "has no `Security: ...` line — quality-gate 4.6 will fall back to "
        "heuristic detection and may miss task-specific constraints"
    ]


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


def grep_symbol_locations(symbol: str, limit: int = 3) -> list[str]:
    """Return up to `limit` `path:line` hits for a whole-word symbol."""
    try:
        out = subprocess.check_output(
            ["git", "grep", "-n", "-w", "--", symbol],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    hits = []
    for line in out.splitlines():
        path, _, rest = line.partition(":")
        lineno, _, _ = rest.partition(":")
        hits.append(f"{path}:{lineno}")
        if len(hits) == limit:
            break
    return hits


# Filenames too generic for a name collision to mean anything.
GENERIC_BASENAMES = {
    "index", "main", "mod", "lib", "app", "utils", "util", "types", "type",
    "constants", "const", "helpers", "helper", "common", "shared", "config",
    "setup", "init", "__init__", "models", "model", "routes", "route", "api",
    "test", "tests", "conftest", "schema", "schemas", "errors", "exceptions",
}
SNAKE_OR_KEBAB = re.compile(r"[_\-]")


def check_create_collisions(items) -> list[str]:
    """Warn when a file the plan will CREATE names a symbol that already exists.

    This is `check_symbols` run backwards. That one asks "does the thing the plan
    cites exist?"; this asks "does the thing the plan intends to invent exist
    already?" — which is the cheaper question to answer at plan time and the more
    expensive one to answer after Phase 3.

    A name collision is a hint, never a verdict: `UserMapper` in two bounded
    contexts is normal, and this is deliberately non-blocking. It exists so the
    reviewer looks, not so the script decides.
    """
    warnings: list[str] = []
    seen: set[str] = set()
    for verb, path in items:
        if verb != "create":
            continue
        stem = Path(path).stem
        if not stem or stem.lower() in GENERIC_BASENAMES or len(stem) < 4:
            continue
        candidates = {stem}
        if SNAKE_OR_KEBAB.search(stem):
            # record_edit_window.py also plausibly declares `RecordEditWindow`
            candidates.add("".join(w.capitalize() for w in SNAKE_OR_KEBAB.split(stem)))
        for symbol in sorted(candidates):
            if symbol in seen:
                continue
            seen.add(symbol)
            hits = grep_symbol_locations(symbol)
            if hits:
                warnings.append(
                    f"plan creates `{path}`, but `{symbol}` already exists: "
                    + ", ".join(hits)
                    + " — confirm the new file isn't a second implementation"
                )
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
        lines.append(
            "Soft signals — typos in cited symbols, missing optional sections, or "
            "declared sections that look thin. Review and fix if applicable; the "
            "plan is not blocked by these."
        )
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
    mirages.extend(validate_acceptance_criteria(text))
    mirages.extend(validate_commit_plan(text, len(items)))
    warnings = check_symbols(text)
    warnings.extend(check_create_collisions(items))
    warnings.extend(check_design_notes(text))
    warnings.extend(check_security_acs(text))

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
