# AR-WORKS — GitHub-backed workspace

Scratchpad repo for arworkflow77-ar/AR-WORKS. The workspace stays tiny (target 0–10 MB);
heavy files (images, audio, video) are pushed here and evicted locally.

## Projects
- _(none yet)_

## How this workspace works
- `./sync.sh "<msg>"` — commit, push, verify, evict every folder in `.heavy`, slim `.git`.
- `./restore.sh <folder>` — temporarily pull a heavy folder back from GitHub.
- `./status.sh` — workspace meter.
- `.heavy` — folders kept on GitHub only.
- Local clone is partial/blobless: `git clone --depth=1 --filter=blob:none https://github.com/arworkflow77-ar/AR-WORKS`
- 2026-09-09 06:19 session health-check: all green
