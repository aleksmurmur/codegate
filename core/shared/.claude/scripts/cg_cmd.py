#!/usr/bin/env python3
"""What a Bash tool call runs, for the push and PR/MR hooks.

A hook matcher names a tool, not a command, so these hooks see every Bash call and ask this
script whether the call is theirs. It reads the hook's JSON on stdin and parses the command
the way a shell splits it: segments joined by `&&`, `||`, `;`, `|`, newlines, subshells and
command substitutions, with `bash -c "..."` and `eval` parsed again. It never runs anything.

Usage:
  cg_cmd.py push   for every `git push`: `ref <branch>` per destination (`HEAD` for the
                   current branch, also when the destination is a variable), and `mr <target>`
                   for an MR the push creates (GitLab push options; `@default` when no target
                   is given, `@unknown` when it is a variable). Exit 1 when there is no push.
  cg_cmd.py pr     `base <branch>` for every `gh pr create` / `glab mr create` (`@default`,
                   `@unknown` as above). Exit 1 when there is none.
"""
from __future__ import annotations

import json
import re
import shlex
import sys

PUNCTUATION = "();<>|&\n"
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
PREFIXES = {"command", "exec", "time", "nohup", "env", "sudo", "$", "{", "!"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
GIT_VALUE_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}


def tokens(cmd: str) -> list[str]:
    # A backtick substitution is a command of its own; outside quotes it splits like `;`.
    lex = shlex.shlex(cmd.replace("`", "\n"), posix=True, punctuation_chars=PUNCTUATION)
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    try:
        return list(lex)
    except ValueError:
        return cmd.replace("`", "\n").split()


def is_punctuation(tok: str) -> bool:
    return bool(tok) and all(c in PUNCTUATION for c in tok)


def segments(cmd: str, depth: int = 0) -> list[list[str]]:
    out: list[list[str]] = []
    seg: list[str] = []
    toks = tokens(cmd)
    i = 0
    while i < len(toks):
        tok = toks[i]
        if is_punctuation(tok) and ("<" in tok or ">" in tok):
            if seg and seg[-1].isdigit():  # the fd of `2>&1`
                seg.pop()
            i += 2  # the redirect and its target
            continue
        if is_punctuation(tok):
            out.append(seg)
            seg = []
        else:
            seg.append(tok)
        i += 1
    out.append(seg)
    result: list[list[str]] = []
    for s in out:
        s = unwrap(s)
        if not s:
            continue
        name = basename(s[0])
        if depth < 3 and name in SHELLS:
            for j, w in enumerate(s[1:], 1):
                if w.startswith("-") and not w.startswith("--") and "c" in w[1:] and j + 1 < len(s):
                    result.extend(segments(s[j + 1], depth + 1))
                    break
            continue
        if depth < 3 and name == "eval":
            result.extend(segments(" ".join(s[1:]), depth + 1))
            continue
        result.append(s)
    return result


def unwrap(seg: list[str]) -> list[str]:
    i = 0
    while i < len(seg) and (seg[i] in PREFIXES or ASSIGNMENT.match(seg[i])):
        i += 1
    return seg[i:]


def basename(word: str) -> str:
    name = word.replace("\\", "/").rsplit("/", 1)[-1]
    return name[:-4] if name.lower().endswith(".exe") else name


def unexpanded(value: str) -> bool:
    return "$" in value or "`" in value


def git_args(seg: list[str], sub: str) -> list[str] | None:
    """The arguments after `git [options] <sub>`, or None when the segment is something else."""
    if basename(seg[0]) != "git":
        return None
    j = 1
    while j < len(seg) and seg[j].startswith("-"):
        j += 2 if seg[j] in GIT_VALUE_OPTIONS else 1
    return seg[j + 1:] if j < len(seg) and seg[j] == sub else None


def branch(ref: str) -> str:
    ref = ref.lstrip("+")
    for prefix in ("refs/heads/", "heads/"):
        if ref.startswith(prefix):
            return ref[len(prefix):]
    return ref


def push_lines(args: list[str]) -> list[str]:
    positional: list[str] = []
    options: list[str] = []
    i = 0
    while i < len(args):
        w = args[i]
        if w in ("-o", "--push-option") and i + 1 < len(args):
            options.append(args[i + 1])
            i += 1
        elif w.startswith("--push-option="):
            options.append(w.split("=", 1)[1])
        elif w.startswith("-o") and len(w) > 2:
            options.append(w[2:])
        elif w in ("--repo", "--receive-pack", "--exec") and i + 1 < len(args):
            i += 1
        elif not w.startswith("-"):
            positional.append(w)
        i += 1
    lines = []
    # Every refspec, not just the last: `git push origin a:main b:x` lands on main too.
    for ref in positional[1:]:
        dest = branch(ref.rsplit(":", 1)[-1] if ":" in ref else ref)
        lines.append("ref " + ("HEAD" if not dest or unexpanded(dest) else dest))
    if not positional[1:]:
        lines.append("ref HEAD")
    mr = [o.split("=", 1)[1] for o in options if o.startswith("merge_request.target=")]
    if mr:
        lines.append("mr " + ("@unknown" if unexpanded(mr[-1]) else mr[-1]))
    elif "merge_request.create" in options:
        lines.append("mr @default")  # GitLab opens it against the default branch
    return lines


def pr_base(seg: list[str]) -> str | None:
    """The base of `gh pr create` / `glab mr create`, `@default` when none is given."""
    tool = basename(seg[0])
    if len(seg) < 3 or (tool, seg[1], seg[2]) not in (("gh", "pr", "create"), ("glab", "mr", "create")):
        return None
    # gh: --base / -B (its -b is the body); glab: --target-branch / -b
    long, short = ("--base", "-B") if tool == "gh" else ("--target-branch", "-b")
    base = "@default"
    args = seg[3:]
    for i, w in enumerate(args):
        if w in (long, short) and i + 1 < len(args):
            base = args[i + 1]
        elif w.startswith(long + "="):
            base = w.split("=", 1)[1]
        elif w.startswith(short) and len(w) > 2 and not w.startswith("--"):
            base = w[2:]
    return "@unknown" if unexpanded(base) else base


def main(argv: list[str]) -> int:
    what = argv[0] if argv else ""
    if what not in ("push", "pr"):
        print(__doc__, file=sys.stderr)
        return 2
    raw = sys.stdin.read()
    try:
        cmd = json.loads(raw).get("tool_input", {}).get("command", "") or ""
    except ValueError:
        cmd = ""
    lines: list[str] = []
    for seg in segments(cmd):
        if what == "push":
            args = git_args(seg, "push")
            if args is not None:
                lines.extend(push_lines(args))
        else:
            base = pr_base(seg)
            if base is not None:
                lines.append("base " + base)
    if not lines:
        return 1
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
