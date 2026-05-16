# install.md — first-time codegate install

You (the agent) are running `/cg-start` against a project that does **not**
have codegate yet. `cg-start.md` has already cloned cg-core to `$TMPDIR`
and confirmed the mode is `install`. Your job: pick the right stack, copy
files into the user's project, and write the manifest.

Project root = current working directory. Cg-core clone = `$TMPDIR`. All
filesystem reads/writes for the user project use paths relative to the
project root (no `../` escapes).

---

## 1. Detect the stack

Each stack overlay lives at `$TMPDIR/core/stacks/<name>/` and declares its
detection signals in its own `stack-manifest.yml`. The `detect:` block
is a list of `"<file> = <substring>"` entries — when the file exists in
the project AND contains the literal substring, that's +1 signal for
that stack. The stack with the most signals wins.

The bash below evaluates every available stack and records its score.
Counter is kept in a plain variable inside a `while … done < file` loop
(no pipe-into-while, which loses the counter in a subshell):

```bash
SCORES="$TMPDIR/.cg-stack-scores"; : > "$SCORES"
ENTRIES="$TMPDIR/.cg-detect-entries"

for SM in "$TMPDIR"/core/stacks/*/stack-manifest.yml; do
  NAME=$(awk '/^name:[[:space:]]/{print $2; exit}' "$SM")

  # Dump every `  - "<file> = <substring>"` line from the `detect:` block.
  awk '
    /^detect:[[:space:]]*$/ { in_detect=1; next }
    in_detect && /^[^[:space:]#]/ { in_detect=0 }
    in_detect && /^[[:space:]]+-[[:space:]]+/ {
      sub(/^[[:space:]]+-[[:space:]]+/, "")
      sub(/^"/, ""); sub(/"$/, "")
      print
    }
  ' "$SM" > "$ENTRIES"

  SCORE=0
  while IFS= read -r ENTRY; do
    [ -z "$ENTRY" ] && continue
    FILE="${ENTRY%% = *}"
    NEEDLE="${ENTRY#* = }"
    if [ -f "$FILE" ] && grep -Fq "$NEEDLE" "$FILE" 2>/dev/null; then
      SCORE=$((SCORE + 1))
    fi
  done < "$ENTRIES"

  printf '%s\t%s\n' "$SCORE" "$NAME" >> "$SCORES"
done

sort -rn "$SCORES" | head -5
rm -f "$ENTRIES"
```

The `$SCORES` file now has `<score>\t<name>` per line, sorted descending.
Read the top row's score and name.

Decision tree:

1. **User passed an explicit hint** (`$ARGUMENTS` contains
   `stack=<name>` or a bare stack name that matches one in
   `core/stacks/`). Trust it, skip heuristics. This is the escape hatch
   for projects where automatic detection misfires.

2. **Single winner, score > 0, no tie.** Use it silently. Set `STACK=<name>`.

3. **Multiple stacks tied at the top with score > 0.** Read each tied
   stack's `description:` field from its manifest and the project's
   build files yourself. Pick the one that fits best. If you're not
   confident, list the tied options to the user with their descriptions
   and ask. Do not arbitrarily pick alphabetical.

4. **All stacks score 0.** No automatic match. Read each stack's
   `description:` and the project's top-level files (build files,
   `package.json`, `pyproject.toml`, source directories) and pick by
   judgment. If unsure, ask the user once, listing names + descriptions.

5. **Cg-core ships zero stacks.** Abort with a clear error — this would
   mean the cg-core checkout is broken.

When you decide on `$STACK`, also note the score and reason in your
final user-facing line. E.g., `stack=kotlin-backend (auto, 4 signals)`
or `stack=react-frontend (your hint)` or `stack=kotlin-backend (chosen
from 2 tied candidates: kotlin-backend, kotlin-multiplatform)`.

---

## 2. Compose the file list

Walk both source directories and build a union (stack wins on overlap).

```bash
SHARED_DIR="$TMPDIR/core/shared"
STACK_DIR="$TMPDIR/core/stacks/$STACK"

[ -d "$STACK_DIR" ] || { echo "ERROR: stack $STACK not found in cg-core"; exit 1; }

# All paths relative to project root after install
{
  ( cd "$SHARED_DIR" && find . -type f -printf "%P\n" )
  ( cd "$STACK_DIR"  && find . -type f -not -name "stack-manifest.yml" -printf "%P\n" )
} | sort -u > "$TMPDIR/.cg-paths"
wc -l "$TMPDIR/.cg-paths"
```

Sanity-check the path list:

- Reject any path containing `..` or starting with `/` — abort install
  with a clear error (this would mean a malformed cg-core).
- Confirm `CLAUDE.md` and `.claude/settings.json` are in the list.

---

## 3. Refuse to overwrite user files

Even though mode is `install`, the project may have a stray `.claude/`
fragment that wasn't enough to trigger `adopt`. Before writing anything:

```bash
COLLISIONS=$(while read p; do [ -e "./$p" ] && echo "$p"; done < "$TMPDIR/.cg-paths")
[ -n "$COLLISIONS" ] && echo "$COLLISIONS"
```

If any collisions exist:

- If the only collision is `CLAUDE.md` (and it's small / trivial) — that's
  probably a generic Claude Code setup file. Show the existing CLAUDE.md
  to the user, ask: "overwrite, abort, or back up to CLAUDE.md.bak first?"
- If multiple files collide — abort and tell the user: "this looks like
  an existing codegate-style setup. Re-run `/cg-start` to enter adopt
  mode (delete `.claude/codegate-installed.yml` if present, then re-run)."

Don't silently overwrite. The principle in design Section 2 (minimum user
involvement) covers updates, not destructive first-write collisions.

---

## 4. Copy files

For each path in `.cg-paths`, pick the source (stack first, then shared)
and copy. Track source for the manifest.

```bash
: > "$TMPDIR/.cg-manifest-files"   # accumulator

while IFS= read -r p; do
  if [ -f "$STACK_DIR/$p" ]; then
    SRC_REL="stacks/$STACK/$p"
    SRC_ABS="$STACK_DIR/$p"
  else
    SRC_REL="shared/$p"
    SRC_ABS="$SHARED_DIR/$p"
  fi
  mkdir -p "./$(dirname "$p")"
  cp "$SRC_ABS" "./$p"
  # Preserve executable bit (hooks, scripts).
  if [ -x "$SRC_ABS" ]; then chmod +x "./$p"; fi
  HASH=$(sha256sum "./$p" | awk '{print $1}')
  printf '%s\t%s\t%s\n' "$p" "$SRC_REL" "$HASH" >> "$TMPDIR/.cg-manifest-files"
done < "$TMPDIR/.cg-paths"

wc -l "$TMPDIR/.cg-manifest-files"
```

After the loop runs, every file from cg-core lives in the user project at
its expected path, and `.cg-manifest-files` has one TAB-separated row per
file: `path \t source \t sha256`.

---

## 5. Write the manifest

```bash
HEAD_SHA=$(git -C "$TMPDIR" rev-parse HEAD)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BRANCH="${BRANCH:-main}"

mkdir -p .claude
{
  echo "codegate_version: $HEAD_SHA"
  echo "stack: $STACK"
  echo "installed_at: $NOW"
  echo "last_updated_at: $NOW"
  echo "ref: $BRANCH"
  echo "files:"
  while IFS=$'\t' read -r path src hash; do
    echo "  - path: $path"
    echo "    source: $src"
    echo "    sha256: $hash"
  done < "$TMPDIR/.cg-manifest-files"
} > .claude/codegate-installed.yml

head -10 .claude/codegate-installed.yml
wc -l .claude/codegate-installed.yml
```

Verify with a `head` and `wc -l` so you can confirm to the user what
was written.

---

## 6. Post-install hint

Tell the user one short line:

> codegate installed for stack=`$STACK`. N files written. Run `/cg-context`
> to seed `.ai/CODEBASE_CONTEXT.md`, then `/cg-feature`, `/cg-bugfix`, or
> `/cg-refactor` to start a task.

Do NOT print the full file list unless the user asks.

---

## 7. Cleanup

`cg-start.md` removes `$TMPDIR` after this runbook returns. Don't do it
yourself — leaving it lets `cg-start.md` retry if anything failed.

---

## Failure mode rules

- If any single `cp` fails — stop, print which file, leave already-copied
  files in place (the user can re-run `/cg-start` after fixing the cause;
  current Stage 0 has no rollback — Stage 1 introduces atomic staging).
- If `git -C "$TMPDIR" rev-parse HEAD` fails — abort, the clone is bad.
- If the manifest already exists at the end (race: another agent ran in
  parallel) — bail with "manifest already exists, run `/cg-start` again
  to enter update mode".
