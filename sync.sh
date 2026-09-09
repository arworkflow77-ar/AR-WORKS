#!/usr/bin/env bash
# sync.sh "<msg>" — commit, push, VERIFY, evict .heavy dirs, slim .git.
# R1: push first, delete second. Never the reverse.
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 1
[ -d .git ] || { echo "sync.sh: not a git repository ($ROOT)"; exit 1; }
BRANCH="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
[ -z "$BRANCH" ] && BRANCH="main"

ws_mb() { du -sk --exclude=.git --exclude=.cache --exclude=node_modules . 2>/dev/null | awk '{printf "%.1f", $1/1024}'; }
ws_files() { find . -type f -not -path "./.git/*" -not -path "./.cache/*" -not -path "*/node_modules/*" | wc -l; }

# ---- 1. commit ----
git add -A
if git diff --cached --quiet; then
  NEW_COMMIT=""
else
  MSG="${1:-sync $(date '+%F %H:%M')}"
  git commit -q -m "$MSG"
  NEW_COMMIT="$(git rev-parse --short HEAD)"
fi

# ---- 2. push (R1: nothing is ever deleted before this succeeds) ----
if ! git push -q origin "$BRANCH" 2>/tmp/sync_push.err; then
  # try rebase-on-remote once (another session may have pushed); never force
  echo "sync.sh: first push failed; attempting rebase on origin/$BRANCH"
  if git fetch -q origin "$BRANCH" && git rebase -q FETCH_HEAD; then
    if ! git push -q origin "$BRANCH" 2>/tmp/sync_push.err; then
      echo "sync.sh: PUSH FAILED twice. Nothing deleted locally." >&2
      sed 's/^/  /' /tmp/sync_push.err >&2
      exit 1
    fi
  else
    echo "sync.sh: PUSH FAILED. Nothing deleted locally." >&2
    sed 's/^/  /' /tmp/sync_push.err >&2
    exit 1
  fi
fi

# ---- 3. verify the push actually landed ----
git fetch -q origin "$BRANCH"
if [ "$(git rev-parse HEAD)" != "$(git rev-parse FETCH_HEAD)" ]; then
  echo "sync.sh: VERIFY FAILED — HEAD != origin/$BRANCH after fetch. Nothing deleted locally." >&2
  exit 1
fi

# ---- 4. evict heavy dirs (marked skip-worktree, then removed) ----
EVICTED=""
if [ -f .heavy ]; then
  while IFS= read -r line; do
    d="${line%%#*}"          # strip comments
    d="$(printf '%s' "$d" | xargs)"  # trim
    [ -n "$d" ] || continue
    d="${d%/}"
    n=$(git ls-files -- "$d" | wc -l)
    if [ "$n" -gt 0 ]; then
      git ls-files -z -- "$d" | git update-index -q --skip-worktree -z --stdin
    fi
    rm -rf "$d"
    EVICTED="$EVICTED $d(+$n)"
  done < .heavy
fi

# ---- 5. slim .git (R4): expel all objects, refetch shallow+blobless ----
# NOTE: .git/objects itself must keep existing (empty) — git discovery requires it.
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
  LEFT=" · WARN: uncommitted changes remain"
fi
echo "✅ Pushed ${NEW_COMMIT:-no-changes} · Workspace: $(ws_mb) MB (limit 20 · red line 50 · cliff 128) · $(ws_files) files · .git $(du -sk .git | awk '{printf "%.1f", $1/1024}') MB · evicted:${EVICTED:- none}$LEFT"
