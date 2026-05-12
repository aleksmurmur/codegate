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

Stage 0 supports one stack: `kotlin-spring` (Kotlin/JVM backend, Spring
Boot or Ktor). Future stages add android-compose, react-frontend, etc.

Run these checks (each is a yes-signal for `kotlin-spring`):

```bash
SIGNALS=0
for f in build.gradle.kts build.gradle; do
  [ -f "$f" ] && grep -qE "org\.springframework\.boot|io\.ktor\.plugin" "$f" && SIGNALS=$((SIGNALS+1))
done
[ -f pom.xml ] && grep -q "spring-boot-starter" pom.xml && SIGNALS=$((SIGNALS+1))
echo "kotlin-spring signals: $SIGNALS"
```

Decision:

- `SIGNALS >= 1` → `STACK=kotlin-spring`. Proceed silently.
- `SIGNALS = 0` → no automatic match. Ask the user once:

  > Codegate currently only ships a kotlin-spring stack overlay. This
  > project doesn't look like Kotlin/Spring/Ktor. Choose:
  >
  > 1. Install with `kotlin-spring` overlay anyway (fine if it's a
  >    JVM project; some prompts will mention Spring/JPA where they
  >    don't apply).
  > 2. Abort. Re-run `/cg-start` once a matching stack overlay exists.
  >
  > (Option 3 — install shared-only, no stack overlay — is intentionally
  > omitted: codebase-intelligence and quality-gate prompts live in the
  > stack layer, so a stackless install would be incomplete.)

  Wait for the user's choice. If they pick (1), set `STACK=kotlin-spring`.
  If (2), stop, no files written.

If the user passed a hint in `$ARGUMENTS` like `stack=android-compose` or
`use kotlin-spring`, treat it as authoritative — skip the heuristic.

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
