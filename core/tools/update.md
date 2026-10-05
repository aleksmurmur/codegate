# update.md — refresh codegate from baseline to upstream HEAD

You (the agent) are running `/cg-start` against a project where the
manifest exists. `cg-start.md` has cloned cg-core to `$TMPDIR` and
confirmed `MODE=update`. Your job: refresh files from upstream, preserve
local modifications, resolve conflicts, and rewrite the manifest. Either
the whole update succeeds or the project is restored to its pre-update
state.

Project root = current working directory. `$TMPDIR` is the cg-core clone.
The manifest lives at `.claude/codegate-installed.yml`.

---

## 1. Read the manifest

```bash
MANIFEST=.claude/codegate-installed.yml
[ -f "$MANIFEST" ] || { echo "ERROR: no manifest"; exit 1; }

BASELINE_SHA=$(awk '/^codegate_version:/{print $2; exit}' "$MANIFEST")
STACK=$(awk '/^stack:/{print $2; exit}' "$MANIFEST")
BRANCH=$(awk '/^ref:/{print $2; exit}' "$MANIFEST")
INSTALLED_AT=$(awk '/^installed_at:/{print $2; exit}' "$MANIFEST")
[ -z "$BRANCH" ] && BRANCH=main

echo "baseline=$BASELINE_SHA stack=$STACK branch=$BRANCH"
for v in "$BASELINE_SHA" "$STACK"; do
  [ -z "$v" ] && { echo "ERROR: manifest is missing required fields"; exit 1; }
done
```

---

## 2. Resolve upstream HEAD

```bash
HEAD_SHA=$(git -C "$TMPDIR" rev-parse HEAD)
echo "upstream HEAD=$HEAD_SHA"

if [ "$HEAD_SHA" = "$BASELINE_SHA" ]; then
  echo "codegate is already at HEAD ($HEAD_SHA). Nothing to do."
  exit 0
fi
```

Ensure the baseline commit is reachable from the temp clone. cg-start.md
clones with `--depth 50` for speed; deepen if the baseline isn't there:

```bash
if ! git -C "$TMPDIR" cat-file -e "$BASELINE_SHA" 2>/dev/null; then
  git -C "$TMPDIR" fetch --unshallow >/dev/null 2>&1 \
    || git -C "$TMPDIR" fetch --depth 500 >/dev/null 2>&1
fi
if ! git -C "$TMPDIR" cat-file -e "$BASELINE_SHA" 2>/dev/null; then
  echo "ERROR: baseline $BASELINE_SHA not reachable in cg-core history"
  exit 1
fi
```

---

## 3. Build path sets

Three things matter:

- **baseline-paths**: every path the manifest knows about.
- **upstream-paths**: every path that exists in `core/shared/` and
  `core/stacks/$STACK/` at HEAD (excluding `stack-manifest.yml`).
- **union-paths**: their union — the full set we walk.

```bash
WORK=$(mktemp -d /tmp/cg-update-XXXXXX)

awk '/^  - path:/{print $3}' "$MANIFEST" | sort -u > "$WORK/baseline-paths"

SHARED_DIR="$TMPDIR/core/shared"
STACK_DIR="$TMPDIR/core/stacks/$STACK"
[ -d "$STACK_DIR" ] || { echo "ERROR: stack $STACK no longer exists in cg-core"; exit 1; }

{
  ( cd "$SHARED_DIR" && find . -type f -printf "%P\n" )
  ( cd "$STACK_DIR"  && find . -type f -not -name "stack-manifest.yml" -printf "%P\n" )
} | sort -u > "$WORK/upstream-paths"

sort -u "$WORK/baseline-paths" "$WORK/upstream-paths" > "$WORK/union-paths"
echo "baseline=$(wc -l < "$WORK/baseline-paths") upstream=$(wc -l < "$WORK/upstream-paths") union=$(wc -l < "$WORK/union-paths")"
```

Reject malformed upstream paths:

```bash
if grep -E "^/|\.\." "$WORK/upstream-paths" >/dev/null; then
  echo "ERROR: cg-core contains malformed paths"; exit 1
fi
```

---

## 4. Compose staging (the new full state)

You will build `$WORK/staging/` so that, after this section, it contains
every file that should exist in the project after the update. Files that
should be deleted are simply absent from staging.

```bash
STAGING="$WORK/staging"
mkdir -p "$STAGING"
CONFLICTS="$WORK/conflicts"; : > "$CONFLICTS"
STATS_NOOP=0 STATS_UPSTREAM=0 STATS_KEPT=0 STATS_MERGED=0 STATS_ADDED=0 STATS_DELETED=0
```

Now walk the union path-by-path. For each `$p`:

```bash
while IFS= read -r p; do
  in_baseline=no; in_upstream=no
  grep -Fxq "$p" "$WORK/baseline-paths" && in_baseline=yes
  grep -Fxq "$p" "$WORK/upstream-paths" && in_upstream=yes

  # === Case A: removed upstream ============================================
  if [ "$in_baseline" = yes ] && [ "$in_upstream" = no ]; then
    STATS_DELETED=$((STATS_DELETED+1))
    continue
  fi

  # === Case B: new in upstream =============================================
  if [ "$in_baseline" = no ] && [ "$in_upstream" = yes ]; then
    if [ -f "$STACK_DIR/$p" ]; then SRC="$STACK_DIR/$p"; else SRC="$SHARED_DIR/$p"; fi
    mkdir -p "$STAGING/$(dirname "$p")"
    cp "$SRC" "$STAGING/$p"
    [ -x "$SRC" ] && chmod +x "$STAGING/$p"
    STATS_ADDED=$((STATS_ADDED+1))
    continue
  fi

  # === Case C: existing on both sides ======================================
  MANIFEST_HASH=$(awk -v want="$p" '
    /^  - path:/    { path=$3 }
    /^    sha256:/  { if (path==want) { print $2; exit } }
  ' "$MANIFEST")
  MANIFEST_SRC=$(awk -v want="$p" '
    /^  - path:/    { path=$3 }
    /^    source:/  { if (path==want) { print $2; exit } }
  ' "$MANIFEST")

  LOCAL_HASH=
  [ -f "./$p" ] && LOCAL_HASH=$(sha256sum "./$p" | awk "{print \$1}")

  if [ -f "$STACK_DIR/$p" ]; then
    UPSTREAM_FILE="$STACK_DIR/$p"; UPSTREAM_SRC_REL="stacks/$STACK/$p"
  else
    UPSTREAM_FILE="$SHARED_DIR/$p"; UPSTREAM_SRC_REL="shared/$p"
  fi
  UPSTREAM_HASH=$(sha256sum "$UPSTREAM_FILE" | awk "{print \$1}")

  # Both sides are compared against the baseline CONTENT, not the manifest hash: manifests
  # written by older updates hold the hash of a kept-local file, which made a local edit read
  # as "unchanged" and get silently overwritten. Hashed on LF so autocrlf is not an edit.
  lf_hash() { sed 's/\r$//' "$1" | sha256sum | awk '{print $1}'; }
  BASE_HASH=
  BASE_PROBE="$WORK/base-probe.$$"
  if git -C "$TMPDIR" show "$BASELINE_SHA:core/$MANIFEST_SRC" > "$BASE_PROBE" 2>/dev/null; then
    BASE_HASH=$(lf_hash "$BASE_PROBE")
  fi
  rm -f "$BASE_PROBE"

  local_changed=no; upstream_changed=no
  if [ -n "$BASE_HASH" ]; then
    [ ! -f "./$p" ] || [ "$(lf_hash "./$p")" != "$BASE_HASH" ] && local_changed=yes
    [ "$(lf_hash "$UPSTREAM_FILE")" != "$BASE_HASH" ] && upstream_changed=yes
  else
    # Baseline content unreachable: fall back to the manifest hash.
    [ "$LOCAL_HASH" != "$MANIFEST_HASH" ] && local_changed=yes
    [ "$UPSTREAM_HASH" != "$MANIFEST_HASH" ] && upstream_changed=yes
  fi

  mkdir -p "$STAGING/$(dirname "$p")"

  if [ "$local_changed" = no ] && [ "$upstream_changed" = no ]; then
    # C1: neither changed → carry local
    [ -f "./$p" ] && cp "./$p" "$STAGING/$p"
    STATS_NOOP=$((STATS_NOOP+1))

  elif [ "$local_changed" = no ] && [ "$upstream_changed" = yes ]; then
    # C2: only upstream changed → apply upstream silently
    cp "$UPSTREAM_FILE" "$STAGING/$p"
    [ -x "$UPSTREAM_FILE" ] && chmod +x "$STAGING/$p"
    STATS_UPSTREAM=$((STATS_UPSTREAM+1))

  elif [ "$local_changed" = yes ] && [ "$upstream_changed" = no ]; then
    # C3: only local changed → keep local
    cp "./$p" "$STAGING/$p"
    STATS_KEPT=$((STATS_KEPT+1))

  else
    # C4: both changed → 3-way merge
    BASE_FILE="$WORK/base.$$.$RANDOM"
    git -C "$TMPDIR" show "$BASELINE_SHA:core/$MANIFEST_SRC" > "$BASE_FILE" 2>/dev/null \
      || { echo "WARN: baseline content unavailable for $p — keeping local"
           cp "./$p" "$STAGING/$p"; STATS_KEPT=$((STATS_KEPT+1)); rm -f "$BASE_FILE"; continue; }

    LOCAL_FILE="$WORK/local.$$.$RANDOM"
    cp "./$p" "$LOCAL_FILE"

    # Normalize line endings across all three inputs before merging.
    # `git show` always emits LF, while the working trees of both the project
    # and the cg-core clone go through the platform's `core.autocrlf`. On
    # Windows that makes base LF and the other two CRLF, so `git merge-file`
    # sees every line as changed on both sides and reports the whole file as
    # one conflict — for every locally-modified file, every update. Merge on
    # LF, then restore CRLF if that is what the project's copy used.
    LOCAL_CRLF=no
    grep -qU $'\r$' "$LOCAL_FILE" 2>/dev/null && LOCAL_CRLF=yes
    for f in "$LOCAL_FILE" "$BASE_FILE"; do
      sed -i 's/\r$//' "$f"
    done
    UPSTREAM_LF="$WORK/upstream-lf.$$.$RANDOM"
    sed 's/\r$//' "$UPSTREAM_FILE" > "$UPSTREAM_LF"

    # mechanical merge first
    if git merge-file -p "$LOCAL_FILE" "$BASE_FILE" "$UPSTREAM_LF" > "$STAGING/$p" 2>/dev/null; then
      [ "$LOCAL_CRLF" = yes ] && sed -i 's/$/\r/' "$STAGING/$p"
      [ -x "$UPSTREAM_FILE" ] && chmod +x "$STAGING/$p"
      STATS_MERGED=$((STATS_MERGED+1))
    else
      # mechanical merge produced conflict markers; staging file may already
      # have them. Defer to agent-driven resolve in step 5.
      printf '%s\n' "$p" >> "$CONFLICTS"
      # Keep the three LF-normalized inputs for step 5, plus whether the
      # project's copy was CRLF so the resolution can be written back in kind.
      mkdir -p "$WORK/conflict-meta"
      printf '%s\t%s\t%s\t%s\n' "$LOCAL_FILE" "$BASE_FILE" "$UPSTREAM_LF" "$LOCAL_CRLF" \
        > "$WORK/conflict-meta/$(echo "$p" | tr '/' '_').tsv"
    fi

    # Special files: even if mechanical merge succeeded, route CLAUDE.md /
    # README.md to a quick agent review. (See step 6.) For now, mark them.
    case "$p" in
      CLAUDE.md|README.md|README_ru.md)
        printf '%s\n' "$p" >> "$WORK/semantic-review"
        ;;
    esac
  fi
done < "$WORK/union-paths"

echo "noop=$STATS_NOOP upstream=$STATS_UPSTREAM kept=$STATS_KEPT merged=$STATS_MERGED added=$STATS_ADDED deleted=$STATS_DELETED conflicts=$(wc -l < "$CONFLICTS")"
```

---

## 5. Resolve conflicts (agent reasoning)

For each path in `$WORK/conflicts`, read three versions and decide.

The conflict-meta file for path `<p>` is at
`$WORK/conflict-meta/$(echo "<p>" | tr '/' '_').tsv` and contains a single
TAB-separated line: `local-file \t base-file \t upstream-file \t local-was-crlf`.

All three are already normalized to LF, so a diff between them shows intent
rather than line endings. If `local-was-crlf` is `yes`, convert the resolved
content back before writing it to staging (`sed -i 's/$/\r/'`) — otherwise the
whole file will read as modified on the project's next update.

Per-path procedure (design Section 10):

1. Read all three files (`local`, `base`, `upstream`).
2. Compute the local diff (local vs base) and the upstream diff (upstream
   vs base). Look at them as intentions, not bytes.
3. Try to auto-resolve:
   - **Equivalent fixes**: if both local and upstream make the same
     functional change (e.g., both fix the same bug, even if textually
     different) — take upstream and note `duplicates-upstream-fix` in
     audit.
   - **Composable changes**: if local and upstream touch the same lines
     but with non-overlapping intent (e.g., local renamed a variable,
     upstream added logic using the old name) — apply both, adjusting
     the upstream's references to the new name.
4. If auto-resolve is unsafe or unclear:
   - Show the user the three versions side-by-side (or as unified diffs
     from base) and a one-paragraph summary of what each side did.
   - Offer: `keep local`, `take upstream`, `manual merge` (open in editor
     — print the staging path with conflict markers).
   - Wait for the user's answer.
5. Write the resolved content to `$STAGING/<p>`. Preserve executable bit
   from upstream if it had one.

Record the outcome for the final report:

```bash
echo "RESOLVED <path> <auto|user> <kept-local|took-upstream|merged|user-edit>" >> "$WORK/resolution-log"
```

If any conflict cannot be resolved (user aborts) — exit non-zero and skip
the apply step. Project remains untouched.

---

## 6. Semantic review for CLAUDE.md / README.md

If `$WORK/semantic-review` exists, each path in it had both local and
upstream changes that mechanical merge resolved cleanly — but these are
structurally important files. Walk them and do a quick agent pass:

For each path `<p>` in `$WORK/semantic-review` and the staging result at
`$STAGING/<p>`:

1. Compare `$STAGING/<p>` against the mechanically-merged result and the
   three inputs.
2. Look specifically for: lost user sections, mid-document upstream
   updates colliding with user additions at the end, orphaned references
   (e.g., an upstream section now refers to a renamed local variable).
3. If everything looks well-integrated: leave `$STAGING/<p>` as-is.
4. If something looks off: rewrite `$STAGING/<p>` semantically — keep
   user additions, apply upstream structural updates verbatim, fix
   cross-references.
5. If the result is non-obvious: show a diff between mechanical and
   semantic results to the user and ask which to keep.

This step is best-effort. Do not block the update on it unless the user
explicitly says "wait, redo".

---

## 7. Build the new manifest

Walk the staged tree, attribute each file (stack first, else shared),
and record the hash of the **upstream** file — what codegate shipped, the
same thing install and adopt record. Not the staged file: for a kept-local
or merged path that is the project's content.

```bash
NEW_MF="$WORK/new-manifest-files"
: > "$NEW_MF"

( cd "$STAGING" && find . -type f -printf "%P\n" ) | sort > "$WORK/staging-paths"

while IFS= read -r p; do
  if [ -f "$STACK_DIR/$p" ]; then SRC_REL="stacks/$STACK/$p"; SRC_FILE="$STACK_DIR/$p"
  else SRC_REL="shared/$p"; SRC_FILE="$SHARED_DIR/$p"
  fi
  HASH=$(sha256sum "$SRC_FILE" | awk "{print \$1}")
  printf '%s\t%s\t%s\n' "$p" "$SRC_REL" "$HASH" >> "$NEW_MF"
done < "$WORK/staging-paths"

# files to delete from project = baseline minus staging
comm -23 "$WORK/baseline-paths" "$WORK/staging-paths" > "$WORK/to-delete"
echo "staging=$(wc -l < "$WORK/staging-paths") to-delete=$(wc -l < "$WORK/to-delete")"
```

---

## 8. Apply atomically (with rollback)

Backup current managed files, then apply. On any failure, restore.

```bash
BACKUP="$WORK/backup"
mkdir -p "$BACKUP"
while IFS= read -r p; do
  if [ -e "./$p" ]; then
    mkdir -p "$BACKUP/$(dirname "$p")"
    cp -a "./$p" "$BACKUP/$p"
  fi
done < "$WORK/baseline-paths"
cp -a "$MANIFEST" "$BACKUP/MANIFEST"

APPLY_FAIL=
while IFS= read -r p; do
  # cp -a into an existing directory silently nests; guard against that.
  if [ -d "./$p" ] && [ ! -L "./$p" ]; then
    APPLY_FAIL="target-is-dir $p"; break
  fi
  mkdir -p "./$(dirname "$p")" || { APPLY_FAIL="mkdir $p"; break; }
  cp -a "$STAGING/$p" "./$p" || { APPLY_FAIL="cp $p"; break; }
done < "$WORK/staging-paths"

if [ -z "$APPLY_FAIL" ]; then
  while IFS= read -r p; do
    rm -f "./$p"
  done < "$WORK/to-delete"
fi

if [ -n "$APPLY_FAIL" ]; then
  echo "ERROR: apply failed at '$APPLY_FAIL' — rolling back"
  # Iterate over every path the apply could have touched: baseline ∪ staging.
  # Files in BACKUP → restore. Files added by upstream that aren't in BACKUP → rm.
  sort -u "$WORK/baseline-paths" "$WORK/staging-paths" > "$WORK/rollback-paths"
  while IFS= read -r p; do
    if [ -e "$BACKUP/$p" ]; then
      mkdir -p "./$(dirname "$p")"
      cp -a "$BACKUP/$p" "./$p"
    else
      rm -f "./$p"
    fi
  done < "$WORK/rollback-paths"
  cp -a "$BACKUP/MANIFEST" "$MANIFEST"
  exit 1
fi
```

---

## 9. Write the new manifest

```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  echo "codegate_version: $HEAD_SHA"
  echo "stack: $STACK"
  echo "installed_at: $INSTALLED_AT"
  echo "last_updated_at: $NOW"
  echo "ref: $BRANCH"
  echo "files:"
  while IFS=$'\t' read -r path src hash; do
    echo "  - path: $path"
    echo "    source: $src"
    echo "    sha256: $hash"
  done < "$NEW_MF"
} > "$MANIFEST"

head -6 "$MANIFEST"
wc -l "$MANIFEST"
```

---

## 10. Surface breaking changes

Walk commits between baseline and HEAD looking for `BREAKING CHANGE`
footers. Conventional commits says: a commit announces a breaking change
by including a `BREAKING CHANGE:` paragraph in its message body. Authors
of cg-core are expected to follow this discipline (see design Section 12).

```bash
BREAKING_LIST="$WORK/breaking-list"; : > "$BREAKING_LIST"
git -C "$TMPDIR" log "$BASELINE_SHA..$HEAD_SHA" --grep='BREAKING CHANGE' --format='%H' \
  > "$BREAKING_LIST"
NBREAKING=$(wc -l < "$BREAKING_LIST")
echo "breaking commits: $NBREAKING"
```

If `$NBREAKING > 0`, render each one for the report. Strip trailing
trailer-style lines (`Co-Authored-By:`, `Signed-off-by:`) from the
breaking block — they're not part of the announcement.

```bash
BREAKING_REPORT="$WORK/breaking-report"; : > "$BREAKING_REPORT"
if [ "$NBREAKING" -gt 0 ]; then
  {
    echo
    echo "Breaking changes between $(echo "$BASELINE_SHA" | cut -c1-7) and $(echo "$HEAD_SHA" | cut -c1-7):"
    while IFS= read -r SHA; do
      SHORT=$(echo "$SHA" | cut -c1-7)
      SUBJ=$(git -C "$TMPDIR" log -1 --format='%s' "$SHA")
      echo
      echo "  $SHORT — $SUBJ"
      git -C "$TMPDIR" log -1 --format='%B' "$SHA" \
        | sed -n '/^BREAKING CHANGE:/,$p' \
        | sed '/^Co-Authored-By:/,$d' \
        | sed '/^Signed-off-by:/,$d' \
        | sed 's/^/    /'
    done < "$BREAKING_LIST"
  } > "$BREAKING_REPORT"
fi
```

If `core/MIGRATIONS.md` exists at HEAD AND there are breaking commits,
add one trailing line pointing the user there. The file is an optional
escape hatch for migrations too complex to fit in a commit footer
(design Section 12) — for v1, just tell the user to read it; do not
attempt to parse or excerpt.

```bash
if [ "$NBREAKING" -gt 0 ] && [ -f "$TMPDIR/core/MIGRATIONS.md" ]; then
  echo "" >> "$BREAKING_REPORT"
  echo "  See core/MIGRATIONS.md in cg-core for additional migration notes." >> "$BREAKING_REPORT"
fi
```

---

## 11. Cleanup + report

`cg-start.md` removes `$TMPDIR`. You handle `$WORK` AFTER you've
captured the breaking report (it lives inside `$WORK`):

```bash
# Capture everything we still need BEFORE deleting $WORK — $CONFLICTS and
# $BREAKING_REPORT both live inside it.
BREAKING_TEXT=
[ -s "$BREAKING_REPORT" ] && BREAKING_TEXT=$(cat "$BREAKING_REPORT")
NCONFLICTS=$(wc -l < "$CONFLICTS" 2>/dev/null || echo 0)
rm -rf "$WORK"
```

Single-line summary to the user, plus any breaking block:

```bash
echo "codegate updated $(echo "$BASELINE_SHA" | cut -c1-7) → $(echo "$HEAD_SHA" | cut -c1-7)."
echo "  upstream taken: $STATS_UPSTREAM, local kept: $STATS_KEPT, merged: $STATS_MERGED, added: $STATS_ADDED, deleted: $STATS_DELETED, conflicts resolved: $NCONFLICTS"
[ -n "$BREAKING_TEXT" ] && printf '%s\n' "$BREAKING_TEXT"
```

If anything in step 5 needed the user's input, surface it in a second
line. If anything in step 6 looked off semantically, surface in a third
line.

Do not dump the full file list unless asked. The breaking block is the
exception — always print it in full when present, regardless of verbosity.

---

## Failure-mode rules

- Any uncaught error before step 8 → project untouched, just `$WORK` to
  clean up.
- Step 8 has rollback. Even partial apply restores.
- If the manifest is corrupt at step 1 — abort, do not "guess" the
  baseline. User should re-run `/cg-start` after manually fixing or
  deleting the manifest (which would re-enter `adopt` mode).
- If a stack rename happened in cg-core (stack no longer at the recorded
  path) — abort. Multi-stack switching is Section 20.3, out of scope for
  Stage 1.
- Never run `rm -rf` on anything outside `$WORK` or already-managed
  project paths. Touch only what the manifest says you own, plus newly
  added upstream files.
