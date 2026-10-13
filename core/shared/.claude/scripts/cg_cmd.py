#!/usr/bin/env python3
"""What a Bash tool call lands where, for the push and PR/MR hook.

A hook matcher names a tool, not a command, so the hook sees every Bash call and asks this
script whether the call is its business. It reads the hook's JSON on stdin and parses the
command the way a shell splits it: segments joined by `&&`, `||`, `;`, `|`, newlines and
subshells; shell keywords and wrappers (`if`, `timeout`, `env` …) skipped; `bash -c "..."`,
`eval` and command substitutions parsed again; comments and heredoc bodies dropped. It never
runs anything. It guards against an agent's mistakes, not against a determined adversary.

Usage: cg_cmd.py
  One line per landing:
    ref <branch> <source>   a `git push` refspec; `HEAD` for the current branch, `@all` for
                            --all / --mirror
    mr <target>             an MR the push opens (GitLab push options)
    base <branch> <head>    a `gh pr create` / `glab mr create` (`new` too)
    dir <path>              first, when the landings run in another checkout (`cd DIR && ...`,
                            `git -C DIR push`); `@unknown` when it is a variable or they differ
  `@default` when no target is given, `@unknown` when it is a variable.
  Exit 1: no push and no PR/MR creation. Exit 3: the command looks like one but cannot be
  parsed (unbalanced quotes and the like).
"""
from __future__ import annotations

import json
import re
import shlex
import sys

PUNCTUATION = "();<>|&\n"
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}"}
# wrapper -> its options that take a value
WRAPPERS = {
    "command": set(), "exec": set(), "builtin": set(), "nohup": set(), "time": set(),
    "stdbuf": set(), "env": {"-u", "-C", "-S"}, "nice": {"-n"}, "sudo": {"-u", "-g"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "xargs": {"-I", "-n", "-L", "-P", "-d", "-a", "-E", "-s"},
}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
GIT_VALUE_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}
# A push or PR/MR creation at the start of a command, for a command that cannot be parsed.
LOOKS_RELEVANT = re.compile(
    r"(^|[;&|(\n`]|\$\()\s*(\S*/)?(git(\.exe)?(\s+-\S+(\s+[^-\s]\S*)?)*\s+push\b"
    r"|(gh|glab)(\.exe)?\s+(pr|mr)\s+(create|new)\b)")
HEREDOC = re.compile(r"<<-?[ \t]*(['\"]?)([A-Za-z0-9_]+)\1")
SUBSTITUTED = "$S"


class Unparsable(Exception):
    pass


def skip_heredocs(cmd: str, i: int, tags: list[str]) -> int:
    """From the start of a line, past the bodies of the heredocs opened on the line before."""
    n = len(cmd)
    for tag in tags:
        while i < n:
            end = cmd.find("\n", i)
            end = n if end < 0 else end
            line, i = cmd[i:end], end + 1
            if line.strip() == tag:
                break
    return i


def closing_paren(cmd: str, i: int) -> int:
    """Index just past the `)` closing a `$(` that opened before i; quotes and heredoc bodies skipped."""
    depth, quote, n = 1, None, len(cmd)
    heredocs: list[str] = []
    while i < n:
        c = cmd[i]
        m = None
        if quote:
            if c == "\\" and quote == '"':
                i += 1
            elif c == quote:
                quote = None
        elif c == "\\":
            i += 1
        elif c in "'\"":
            quote = c
        elif cmd.startswith("<<", i) and (m := HEREDOC.match(cmd, i)):
            heredocs.append(m.group(2))
            i = m.end()
            continue
        elif c == "\n" and heredocs:
            i = skip_heredocs(cmd, i + 1, heredocs)
            heredocs = []
            continue
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def prepass(cmd: str) -> tuple[str, list[str]]:
    """Drop comments and heredoc bodies; lift command substitutions out as commands of their own."""
    out: list[str] = []
    inner: list[str] = []
    heredocs: list[str] = []
    quote = None
    i, n = 0, len(cmd)
    while i < n:
        c = cmd[i]
        if quote == "'":
            out.append(c)
            quote = None if c == "'" else quote
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            if cmd[i + 1] != "\n":  # a line continuation joins the two lines
                out.append(cmd[i:i + 2])
            i += 2
            continue
        if quote is None and cmd.startswith("$'", i):  # ANSI-C quoting: content does not matter
            j = i + 2
            while j < n and cmd[j] != "'":
                j += 2 if cmd[j] == "\\" else 1
            out.append("'_'")
            i = j + 1
            continue
        if cmd.startswith("$(", i) and not cmd.startswith("$((", i):
            j = closing_paren(cmd, i + 2)
            inner.append(cmd[i + 2:j - 1])
            out.append(SUBSTITUTED)
            i = j
            continue
        if c == "`":
            j = cmd.find("`", i + 1)
            j = n if j < 0 else j
            inner.append(cmd[i + 1:j])
            out.append(SUBSTITUTED)
            i = j + 1
            continue
        if quote == '"':
            out.append(c)
            quote = None if c == '"' else quote
            i += 1
            continue
        if c in "'\"":
            quote = c
        elif c == "#" and (i == 0 or cmd[i - 1] in " \t\n;&|()"):
            while i < n and cmd[i] != "\n":
                i += 1
            continue
        elif cmd.startswith("<<", i) and not cmd.startswith("<<<", i):
            m = HEREDOC.match(cmd, i)
            if m:
                heredocs.append(m.group(2))
                out.append("<< _")
                i = m.end()
                continue
        elif c == "\n" and heredocs:
            out.append(c)
            i = skip_heredocs(cmd, i + 1, heredocs)
            heredocs = []
            continue
        out.append(c)
        i += 1
    return "".join(out), inner


def tokens(cmd: str) -> list[str]:
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=PUNCTUATION)
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    try:
        return list(lex)
    except ValueError as e:
        raise Unparsable(str(e))


def is_punctuation(tok: str) -> bool:
    return bool(tok) and all(c in PUNCTUATION for c in tok)


def segments(cmd: str, depth: int = 0) -> list[list[str]]:
    outer, inner = prepass(cmd)
    raw: list[list[str]] = []
    seg: list[str] = []
    toks = tokens(outer)
    i = 0
    while i < len(toks):
        tok = toks[i]
        if is_punctuation(tok) and ("<" in tok or ">" in tok):
            if seg and seg[-1].isdigit():  # the fd of `2>&1`
                seg.pop()
            i += 2  # the redirect and its target
            continue
        if is_punctuation(tok):
            raw.append(seg)
            seg = []
        else:
            seg.append(tok)
        i += 1
    raw.append(seg)
    result: list[list[str]] = []
    for s in raw:
        s = unwrap(s)
        if not s:
            continue
        name = basename(s[0])
        if depth < 3 and name in SHELLS:
            for j, w in enumerate(s[1:], 1):
                if w.startswith("-") and not w.startswith("--") and "c" in w[1:]:
                    rest = s[j + 1:]
                    if rest[:1] == ["--"]:
                        rest = rest[1:]
                    if rest:
                        result.extend(segments(rest[0], depth + 1))
                    break
            continue
        if depth < 3 and name == "eval":
            result.extend(segments(" ".join(s[1:]), depth + 1))
            continue
        result.append(s)
    if depth < 3:
        for sub in inner:
            result.extend(segments(sub, depth + 1))
    return result


def unwrap(seg: list[str]) -> list[str]:
    i = 0
    while i < len(seg):
        w = seg[i]
        name = basename(w)
        if w in KEYWORDS or ASSIGNMENT.match(w):
            i += 1
        elif name in WRAPPERS:
            takes_value = WRAPPERS[name]
            i += 1
            while i < len(seg) and seg[i].startswith("-"):
                i += 2 if seg[i] in takes_value else 1
            if name == "timeout" and i < len(seg):
                i += 1  # the duration
        else:
            break
    return seg[i:]


def basename(word: str) -> str:
    name = word.replace("\\", "/").rsplit("/", 1)[-1]
    return name[:-4] if name.lower().endswith(".exe") else name


def unexpanded(value: str) -> bool:
    return "$" in value or "`" in value


def git_args(seg: list[str], sub: str) -> tuple[list[str], str] | None:
    """The arguments after `git [options] <sub>` and the `-C` directory ("" when none)."""
    if basename(seg[0]) != "git":
        return None
    j, where = 1, ""
    while j < len(seg) and seg[j].startswith("-"):
        if seg[j] == "-C" and j + 1 < len(seg):
            where = join(where, seg[j + 1])
        j += 2 if seg[j] in GIT_VALUE_OPTIONS else 1
    return (seg[j + 1:], where) if j < len(seg) and seg[j] == sub else None


def join(where: str, path: str) -> str:
    if where == "@unknown" or unexpanded(path):
        return "@unknown"
    path = path.replace("\\", "/")
    if not where or path.startswith("/") or (len(path) > 1 and path[1] == ":"):
        return path
    return f"{where.rstrip('/')}/{path}"


def branch(ref: str) -> str:
    ref = ref.lstrip("+")
    for prefix in ("refs/heads/", "heads/"):
        if ref.startswith(prefix):
            return ref[len(prefix):]
    return ref


def known(value: str) -> str:
    return "HEAD" if not value or unexpanded(value) else value


def push_lines(args: list[str]) -> list[str]:
    positional: list[str] = []
    options: list[str] = []
    repo_given = every_branch = tags_only = False
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
        elif w == "--repo" and i + 1 < len(args):
            repo_given = True
            i += 1
        elif w.startswith("--repo="):
            repo_given = True
        elif w in ("--all", "--mirror", "--branches"):
            every_branch = True
        elif w == "--tags":
            tags_only = True
        elif w in ("--receive-pack", "--exec") and i + 1 < len(args):
            i += 1
        elif not w.startswith("-"):
            positional.append(w)
        i += 1
    refspecs = positional if repo_given else positional[1:]
    lines = []
    if every_branch:
        lines.append("ref @all HEAD")
    # Every refspec, not just the last: `git push origin a:main b:x` lands on main too.
    for ref in refspecs:
        src, dst = ref.rsplit(":", 1) if ":" in ref else (ref, ref)
        dst = branch(dst)
        dst = "@unknown" if unexpanded(dst) else (dst or "HEAD")
        lines.append(f"ref {dst} {known(src.lstrip('+')) if src else '-'}")
    if not refspecs and not every_branch and not tags_only:
        lines.append("ref HEAD HEAD")
    mr = [o.split("=", 1)[1] for o in options if o.startswith("merge_request.target=")]
    if mr:
        lines.append("mr " + ("@unknown" if unexpanded(mr[-1]) else mr[-1]))
    elif "merge_request.create" in options:
        lines.append("mr @default")  # GitLab opens it against the default branch
    return lines


def pr_line(seg: list[str]) -> str | None:
    """`base <branch> <head>` for `gh pr create` / `glab mr create`, or None."""
    tool = basename(seg[0])
    if len(seg) < 3 or (tool, seg[1]) not in (("gh", "pr"), ("glab", "mr")) or seg[2] not in ("create", "new"):
        return None
    # gh: --base / -B (its -b is the body), --head / -H; glab: --target-branch / -b, --source-branch / -s
    names = {"base": ("--base", "-B"), "head": ("--head", "-H")} if tool == "gh" else \
        {"base": ("--target-branch", "-b"), "head": ("--source-branch", "-s")}
    found = {"base": "@default", "head": "HEAD"}
    args = seg[3:]
    for i, w in enumerate(args):
        for key, (long, short) in names.items():
            if w in (long, short) and i + 1 < len(args):
                found[key] = args[i + 1]
            elif w.startswith(long + "="):
                found[key] = w.split("=", 1)[1]
            elif w.startswith(short) and len(w) > 2 and not w.startswith("--"):
                found[key] = w[2:]
    base = "@unknown" if unexpanded(found["base"]) else found["base"]
    return f"base {base} {known(found['head'])}"


def main() -> int:
    raw = sys.stdin.read()
    try:
        cmd = json.loads(raw).get("tool_input", {}).get("command", "") or ""
    except ValueError:
        cmd = ""
    try:
        segs = segments(cmd)
    except Unparsable:
        outer, inner = prepass(cmd)
        return 3 if any(LOOKS_RELEVANT.search(c) for c in [outer, *inner]) else 1
    lines: list[str] = []
    dirs: set[str] = set()
    where = ""  # set by a `cd` earlier in the command
    for seg in segs:
        if seg[0] == "cd":
            where = join(where, seg[1]) if len(seg) > 1 and seg[1] != "-" else "@unknown"
            continue
        pushed = git_args(seg, "push")
        if pushed is not None:
            lines.extend(push_lines(pushed[0]))
            dirs.add(join(where, pushed[1]) if pushed[1] else where)
        pr = pr_line(seg)
        if pr:
            lines.append(pr)
            dirs.add(where)
    if not lines:
        return 1
    if dirs != {""}:
        lines.insert(0, "dir " + (dirs.pop() if len(dirs) == 1 and "" not in dirs else "@unknown"))
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
