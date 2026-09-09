#!/usr/bin/env bash
# status.sh — workspace meter (R3).
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 1
WS_KB=$(du -sk --exclude=.git --exclude=.cache --exclude=node_modules . 2>/dev/null | cut -f1)
WS_MB=$(awk -v k="${WS_KB:-0}" 'BEGIN{printf "%.1f", k/1024}')
FILES=$(find . -type f -not -path "./.git/*" -not -path "./.cache/*" -not -path "*/node_modules/*" | wc -l)
GIT_MB=$(du -sk .git 2>/dev/null | awk '{printf "%.1f", $1/1024}')
echo "Workspace: $WS_MB MB / 128 MB · $FILES files · .git: $GIT_MB MB"
echo "Thresholds: normal <10 · STOP 20 · EMERGENCY 35 · NEVER 50"
HEAVY=$(sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' .heavy 2>/dev/null | tr '\n' ' ')
[ -n "$HEAVY" ] && echo "Heavy (GitHub-only after push):$HEAVY"
echo "Largest items:"
du -sk --exclude=.git --exclude=.cache --exclude=node_modules ./* ./.??* 2>/dev/null | sort -rn | head -5 | awk '{printf "  %.0f KB  %s\n", $1, $2}'
awk -v m="$WS_MB" 'BEGIN{
  if (m >= 50) print "🔴 RED LINE CROSSED — 50 MB — evict everything NOW";
  else if (m >= 35) print "🟠 EMERGENCY — 35 MB — push + evict everything in .heavy, wipe caches";
  else if (m >= 20) print "🟡 STOP — 20 MB — sync + evict before producing anything new";
  else if (m >= 10) print "⚠️  over 10 MB — plan the next batch to stay under it";
  else print "✅ healthy (0-10 MB)";
}'
