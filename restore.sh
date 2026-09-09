#!/usr/bin/env bash
# restore.sh <folder> — pull a heavy folder back from GitHub temporarily (R7).
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 1
[ -d .git ] || { echo "restore.sh: not a git repository"; exit 1; }
dir="${1:-}"
if [ -z "$dir" ]; then
  echo "Usage: ./restore.sh <folder>"
  echo "Heavy folders (.heavy): $(grep -v '^#' .heavy 2>/dev/null | grep -v '^[[:space:]]*$' | tr '\n' ' ')"
  exit 1
fi
dir="${dir%/}"
git ls-files -z -- "$dir" | git update-index -q --no-skip-worktree -z --stdin
if git checkout -q HEAD -- "$dir"; then
  echo "Restored $dir ($(git ls-files -- "$dir" | wc -l) files). Run ./sync.sh to re-evict."
else
  echo "restore.sh: failed to restore $dir" >&2
  exit 1
fi
