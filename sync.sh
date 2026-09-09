#!/usr/bin/env bash
# sync.sh "<msg>" — commit → push → VERIFY → evict .heavy dirs → slim .git.
# R1: push first, delete second. Never the reverse.
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 1
[ -d .git ] || { echo "sync.sh: not a git repository ($ROOT)"; exit 1; }
BRANCH="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
[ -z "$BRANCH" ] && BRANCH="main"

# ---- 0. one sync at a time (prevents two syncs corrupting each other) ----
if command -v flock >/dev/null 2>&1; then
  exec 9>/tmp/sync.lock
  flock -n 9 || { echo "sync.sh: another sync already running"; exit 1; }
fi

ws_mb() { du -sk --exclude=.git --exclude=.cache --exclude=node_modules . 2>/dev/null | awk '{printf "%.1f", $1/1024}'; }
ws_files() { find . -type f -not -path "./.git/*" -not -path "./.cache/*" -not -path "*/node_modules/*" | wc -l; }
BEFORE=$(ws_mb)

# ---- 1. commit ----
git add -A
if git diff --cached --quiet; then
  NEW_COMMIT=""
else
  MSG="${1:-sync $(date '+%F %H:%M')}"
  git commit -q -m "$MSG"
  NEW_COMMIT="$(git rev-parse --short HEAD)"
fi

# ---- 2. push (R1: nothing is deleted before this succeeds) ----
if ! git push -q origin "$BRANCH" 2>/tmp/sync_push.err; then
  echo "sync.sh: first push failed — fetching + rebasing (never force)"
  if git fetch -q origin "$BRANCH" && git rebase -q FETCH_HEAD 2>/tmp/sync_rebase.err; then
    if ! git push -q origin "$BRANCH" 2>/tmp/sync_push.err; then
      echo "sync.sh: PUSH FAILED twice. Nothing deleted locally." >&2
      sed 's/^/  /' /tmp/sync_push.err >&2
      exit 1
    fi
  else
    git rebase --abort 2>/dev/null
    echo "sync.sh: PUSH FAILED — rebase conflict. Nothing deleted locally. Resolve manually, then run sync.sh again." >&2
    sed 's/^/  /' /tmp/sync_rebase.err >&2
    exit 1
  fi
fi

# ---- 3. verify the push landed (adopt remote if it moved ahead cleanly) ----
git fetch -q origin "$BRANCH"
if [ "$(git rev-parse HEAD)" != "$(git rev-parse FETCH_HEAD)" ]; then
  if git merge-base --is-ancestor HEAD FETCH_HEAD; then
    echo "sync.sh: remote moved ahead (another session pushed) — fast-forwarding local"
    git merge --ff-only -q FETCH_HEAD || { echo "sync.sh: VERIFY FAILED. Nothing deleted locally." >&2; exit 1; }
  else
    echo "sync.sh: VERIFY FAILED — local diverged from origin/$BRANCH. Nothing deleted locally." >&2
    exit 1
  fi
fi

# ---- 4. evict heavy dirs (skip-worktree mark, then remove) ----
EVICTED=""
if [ -f .heavy ]; then
  while IFS= read -r line; do
    d="${line%%#*}"
    d="$(printf '%s' "$d" | xargs)"
    [ -n "$d" ] || continue
    d="${d%/}"
    case "$d" in
      "."|".."|".."*|"/"|"/"*|"~"*|*"/.."|*"/../"*)
        echo "sync.sh: SKIP invalid .heavy entry: '$d'" >&2; continue;;
    esac
    n=$(git ls-files -- "$d" | wc -l)
    if [ "$n" -gt 0 ]; then
      git ls-files -z -- "$d" | git update-index -q --skip-worktree -z --stdin
    fi
    rm -rf "$d"
    EVICTED="$EVICTED $d(+$n)"
  done < .heavy
fi

# ---- 4b. R2 safety: warn about heavy content NOT listed in .heavy ----
HEAVY_STR=$(sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' .heavy 2>/dev/null)
WARN=$(git ls-tree -r -l HEAD 2>/dev/null | awk -v heavy="$HEAVY_STR" '
BEGIN { n = split(heavy, H, "\n"); }
function underh(path,   i) {
  for (i = 1; i <= n; i++) {
    if (H[i] == "") continue;
    if (path == H[i] || index(path, H[i] "/") == 1) return 1;
  }
  return 0;
}
$2 == "blob" {
  p = $5;
  if ($4 > 200000 && !underh(p)) files = files (files ? ", " : "") p " (" int($4/1024) " KB)";
  d = p; sub(/\/[^\/]*$/, "", d);
  if (d != "" && !underh(d)) cnt[d]++;
}
END {
  msg = files;
  for (d in cnt) if (cnt[d] > 20) msg = msg (msg ? " · " : "") d "/ (" cnt[d] " files)";
  if (msg) print msg;
}')
if [ -n "$WARN" ]; then
  echo "sync.sh: ⚠ R2 — heavy content NOT in .heavy: $WARN — add the folder to .heavy"
fi

# ---- 5. slim .git (R4): expel all objects, refetch shallow+blobless ----
# NOTE: .git/objects must keep existing (empty) — git discovery requires it.
git reflog expire --expire=now --all
rm -rf /tmp/objects-backup && mkdir -p /tmp/objects-backup
if ls .git/objects/* >/dev/null 2>&1; then mv .git/objects/* /tmp/objects-backup/; fi
if ! git fetch -q --depth=1 origin "$BRANCH"; then
  echo "sync.sh: shallow refetch failed; retrying full blobless fetch"
  git fetch -q origin "$BRANCH"
fi
if ! git rev-parse -q --verify HEAD >/dev/null 2>&1; then
  echo "sync.sh: refetch FAILED — restoring previous objects" >&2
  rm -rf .git/objects && mv /tmp/objects-backup .git/objects
else
  rm -rf /tmp/objects-backup
fi
git repack -a -d -q
git prune-packed -q
rm -rf .cache/pip 2>/dev/null

# ---- 6. report (R8) ----
LEFT=""
if [ "$(git status --porcelain | wc -l)" -ne 0 ]; then
  LEFT=" · ⚠ uncommitted changes remain"
fi
echo "✅ Pushed ${NEW_COMMIT:-no-changes} · Workspace: $BEFORE → $(ws_mb) MB (limit 20 · red line 50 · cliff 128) · $(ws_files) files · .git $(du -sk .git | awk '{printf "%.1f", $1/1024}') MB · evicted:${EVICTED:- none}$LEFT"
