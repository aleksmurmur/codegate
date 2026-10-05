# adopt.md — migrate a copy-paste codegate setup into managed mode

You (the agent) are running `/cg-start` against a project that has a
codegate-shaped layout (e.g., `CLAUDE.md`, `.claude/agents/...`) but no
manifest. `cg-start.md` has cloned cg-core to `$TMPDIR` and confirmed
`MODE=adopt`. Your job: figure out which cg-core commit the local files
descended from, write a manifest at that commit, then chain into the
update flow so HEAD's changes land in the same pass.

Project root = current working directory. `$TMPDIR` is the cg-core clone.

---

## 1. Detect the stack

Walk every stack overlay in `$TMPDIR/core/stacks/`, read its
`stack-manifest.yml`, evaluate the `detect:` block (each entry is
`"<file> = <substring>"` — file must exist in the project AND contain
the substring for +1 signal):

```bash
WORK=$(mktemp -d /tmp/cg-adopt-XXXXXX)
SCORES="$WORK/stack-scores"; : > "$SCORES"
ENTRIES="$WORK/detect-entries"

for SM in "$TMPDIR"/core/stacks/*/stack-manifest.yml; do
  NAME=$(awk '/^name:[[:space:]]/{print $2; exit}' "$SM")
  awk '
    /^detect:[[:space:]]*$/ { in_detect=1; next }
    in_detect && /^[^[:space:]#]/ { in_detect=0 }
    in_detect && /^[[:space:]]+-[[:space:]]+/ {
      sub(/^[[:space:]]+-[[:space:]]+/, "")
      print
    }
  ' "$SM" > "$ENTRIES"

  SCORE=0
  while IFS= read -r ENTRY; do
    [ -z "$ENTRY" ] && continue
    ENTRY="${ENTRY#[\"\']}"
    ENTRY="${ENTRY%[\"\']}"
    ENTRY="${ENTRY//\\\"/\"}"
    FILE="${ENTRY%% = *}"; NEEDLE="${ENTRY#* = }"
    if [ -f "$FILE" ] && grep -Fq "$NEEDLE" "$FILE" 2>/dev/null; then
      SCORE=$((SCORE + 1))
    fi
  done < "$ENTRIES"
  printf '%s\t%s\n' "$SCORE" "$NAME" >> "$SCORES"
done

sort -rn "$SCORES" | head -5
rm -f "$ENTRIES"
```

Decision tree — same as `install.md` step 1:

1. **Explicit `$ARGUMENTS` hint** → trust it.
2. **Single winner, score > 0** → use silently.
3. **Tied winners with score > 0** → read each manifest's
   `description:` and decide; ask user only if not confident.
4. **All scores 0** → degraded detection. For adopt specifically you
   have an extra signal: read the existing local
   `.claude/agents/codebase-intelligence/prompt.md` (if present) — it
   often contains stack-specific language (Spring/JPA/Ktor, Compose,
   React, Django) that survives from the original copy-paste install.
   Use that plus project files to pick. Ask only if still unclear.
5. **Zero stacks shipped in cg-core** → abort.

Store result in `$STACK`.

---

## 2. Collect local codegate-shaped files

Hash everything in the project that looks like managed codegate content,
skipping codegate's own bookkeeping and gitignored locals. `$WORK` was
already created in step 1.

```bash
: > "$WORK/local-hashes"

# Root-level installable docs
for f in CLAUDE.md README.md README_ru.md; do
  if [ -f "$f" ]; then
    H=$(sha256sum "$f" | awk '{print $1}')
    printf '%s\t%s\n' "$f" "$H" >> "$WORK/local-hashes"
  fi
done

# Everything under .claude/, minus bookkeeping
if [ -d .claude ]; then
  find .claude -type f \
    -not -name codegate-installed.yml \
    -not -name settings.local.json \
    -printf "%p\n" \
  | while IFS= read -r p; do
      # strip leading "./" if present (it isn't with -printf "%p", but defensive)
      P=${p#./}
      H=$(sha256sum "$P" | awk '{print $1}')
      printf '%s\t%s\n' "$P" "$H" >> "$WORK/local-hashes"
    done
fi

sort -u "$WORK/local-hashes" > "$WORK/local-hashes.sorted"
echo "local files: $(wc -l < "$WORK/local-hashes.sorted")"
```

If `$WORK/local-hashes.sorted` is empty — the project has no
codegate-shaped content despite the adopt trigger. Abort: tell the user
this looks like a fresh install candidate, suggest deleting the empty
`.claude/` if any and re-running.

---

## 3. Build the eligible-commit list

Only commits where `core/shared/` exists in the tree are valid baseline
candidates. The cg-starter / cg-core distribution model was introduced
at the Stage 0 commit; everything older had the legacy flat layout and
is not addressable as a "baseline" in this scheme.

```bash
git -C "$TMPDIR" rev-list HEAD | while IFS= read -r C; do
  if git -C "$TMPDIR" cat-file -e "$C:core/shared" 2>/dev/null; then
    echo "$C"
  fi
done > "$WORK/eligible-commits"

NCANDIDATES=$(wc -l < "$WORK/eligible-commits")
[ "$NCANDIDATES" = 0 ] && { echo "ERROR: cg-core has no Stage-0+ commits"; exit 1; }
echo "eligible commits: $NCANDIDATES"
```

Pre-Stage-0 layouts are NOT scored. A user adopting from a legacy clone
will get HEAD as their baseline (because nothing scores higher than 0)
and the subsequent update will treat every local file as a candidate for
3-way merge against HEAD's content. That's an acceptable degraded mode.

---

## 4. Score each eligible commit

For commit `C`, build the install-path → sha256 map from
`core/shared/` ∪ `core/stacks/$STACK/`. Score = number of
`(install_path, sha256)` pairs that match the local set.

```bash
BEST_SHA=
BEST_SCORE=-1

while IFS= read -r C; do
  : > "$WORK/c-hashes"
  # Tree paths under core/shared and core/stacks/$STACK at C
  git -C "$TMPDIR" ls-tree -r "$C" core/shared core/stacks/"$STACK" 2>/dev/null \
    | awk '{print $NF}' > "$WORK/c-paths-raw"

  while IFS= read -r rp; do
    case "$rp" in
      core/shared/*)         INST=${rp#core/shared/} ;;
      core/stacks/"$STACK"/*) INST=${rp#core/stacks/"$STACK"/}
                              [ "$INST" = "stack-manifest.yml" ] && continue ;;
      *) continue ;;
    esac
    H=$(git -C "$TMPDIR" show "$C:$rp" | sha256sum | awk '{print $1}')
    printf '%s\t%s\n' "$INST" "$H" >> "$WORK/c-hashes"
  done < "$WORK/c-paths-raw"

  sort -u "$WORK/c-hashes" > "$WORK/c-hashes.sorted"
  SCORE=$(comm -12 "$WORK/local-hashes.sorted" "$WORK/c-hashes.sorted" | wc -l)

  if [ "$SCORE" -gt "$BEST_SCORE" ]; then
    BEST_SCORE=$SCORE
    BEST_SHA=$C
    cp "$WORK/c-hashes.sorted" "$WORK/best-c-hashes"
  fi
done < "$WORK/eligible-commits"

echo "BEST_SHA=$BEST_SHA SCORE=$BEST_SCORE LOCAL=$(wc -l < "$WORK/local-hashes.sorted")"
```

Iteration order is newest-first (because `git rev-list HEAD` returns
reverse-chrono), and the strict-`-gt` comparison keeps the newest commit
on ties. So a file that hasn't changed in 10 commits lands on the
newest of those 10.

Verdict:
- `SCORE == NLOCAL`: exact match. Every local file has a path+hash twin
  at `BEST_SHA`. Tell the user "adopted at exact match $(short $BEST_SHA)".
- `0 < SCORE < NLOCAL`: approximate match. Some local files diverge.
  Those divergences will read as local edits to the update flow.
- `SCORE == 0`: no overlap. Pick HEAD as baseline and warn the user —
  this is the degraded mode for legacy / heavily-modified projects.

---

## 5. Optional user hint

The user may have passed free-text in `$ARGUMENTS` such as:

> "scripts/diff-coverage.py is mine, leave it alone"

Stage 2 records the hint in the audit (see step 8) but does **not** alter
the manifest based on it. Reason: the manifest stores baseline hashes;
local divergence is preserved by 3-way merge during the chained update,
which already gives the user their content back via case C3/C4. A
dedicated "pin local" mechanism is Stage 5+ polish.

If the hint contradicts the detected stack (e.g., "I'm Android, switch
stacks"), surface that to the user and abort — multi-stack switching is
out of scope.

---

## 6. Write the manifest with BASELINE hashes

The manifest records what cg-core@BEST_SHA looked like, not what the
project currently looks like. Local divergence is intentional: the
update flow's `local_changed` check will fire on those files and route
them through 3-way merge, which is exactly what the design promised
("это и есть локальные изменения").

```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BRANCH=${BRANCH:-main}
HEAD_SHA=$(git -C "$TMPDIR" rev-parse HEAD)

mkdir -p .claude
{
  echo "codegate_version: $BEST_SHA"
  echo "stack: $STACK"
  echo "installed_at: $NOW"
  echo "last_updated_at: $NOW"
  echo "ref: $BRANCH"
  echo "files:"
  while IFS=$'\t' read -r p h; do
    # Determine source (stack first, else shared) — same precedence as install.
    if git -C "$TMPDIR" cat-file -e "$BEST_SHA:core/stacks/$STACK/$p" 2>/dev/null; then
      SRC="stacks/$STACK/$p"
    else
      SRC="shared/$p"
    fi
    echo "  - path: $p"
    echo "    source: $SRC"
    echo "    sha256: $h"
  done < "$WORK/best-c-hashes"
} > .claude/codegate-installed.yml

echo "manifest written; entries: $(grep -c '^  - path:' .claude/codegate-installed.yml)"
```

Files that are **only** in the user's project (not in cg-core@BEST_SHA)
are simply absent from the manifest — they remain user-owned and the
update flow never touches them. If cg-core@HEAD adds the same path, the
subsequent update will create a fresh upstream file at the same path,
overwriting the user-only file. That's a recognized edge case for v1;
the agent should mention it in the post-adopt report if any user-only
paths exist under `.claude/`.

---

## 7. Chain into update

The manifest now reflects an `install` at `BEST_SHA`. If `HEAD_SHA` is
different (the common case), the project needs the post-baseline
changes applied. Don't reimplement the update logic here — re-read the
update runbook and follow it:

```bash
echo "Now running update flow to bring baseline → HEAD and ask the options"
RUNBOOK="$TMPDIR/core/tools/update.md"
# Hand off: read $RUNBOOK and execute it step-by-step against the
# manifest we just wrote.
```

Practically: after this section, read `core/tools/update.md` in the
clone and execute its sections 1–10 normally. They'll find the manifest
you just created, see `codegate_version=$BEST_SHA`, `HEAD_SHA != BEST_SHA`,
and proceed. Local-divergence files will surface as
`local_changed=yes` and merge correctly.

Run update even when `BEST_SHA == HEAD_SHA`: the manifest written above has
no `options:`, and update's step 1b is what asks for them.

---

## 8. Report

Single short line, plus a second line if there was anything notable:

```
codegate adopted at $(short $BEST_SHA) (matched M of N files). Then updated to $(short $HEAD_SHA): X changes, Y conflicts, Z user-only files left alone.
```

Mention specifically if:
- `SCORE == 0` (no overlap; degraded mode — user-only adoption at HEAD).
- Any path appears only locally (user-owned files, listed by name if ≤ 5;
  count only otherwise).
- The chained update produced conflicts that needed user input.

---

## 9. Cleanup

`cg-start.md` removes `$TMPDIR`. You handle `$WORK`:

```bash
rm -rf "$WORK"
```

---

## Failure-mode rules

- If no eligible commits exist in cg-core → abort with a clear message
  (this would mean cg-core's history doesn't have Stage 0).
- If the scoring loop fails for a specific commit (git show error,
  bad tree) → skip that commit, don't fail the whole adopt.
- If step 6 (manifest write) fails — leave the project untouched, no
  partial manifest. Manifest is atomic by virtue of being a single
  write to a single file.
- If step 7 (chained update) fails — the manifest still exists, so a
  subsequent `/cg-start` will enter update mode directly. No re-adopt
  needed. Surface the update error to the user.
