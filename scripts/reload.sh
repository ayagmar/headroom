#!/usr/bin/env bash
# Makes the running Noctalia pick up this checkout after it changed on disk.
#
# .luau files hot-reload on their own. The manifest and translations are only
# read when the plugin is enabled, so when those changed (or when called with
# --force) the plugin is disabled and re-enabled. Called by the git hooks in
# .githooks/ after pull, merge, rebase and checkout; safe to run by hand.
#
# Usage: scripts/reload.sh [--force] [<old-rev> <new-rev>]
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGIN_ID="ayagmar/headroom"

command -v noctalia >/dev/null 2>&1 || exit 0
noctalia msg plugins list >/dev/null 2>&1 || exit 0 # shell not running

force=0
if [[ "${1:-}" == "--force" ]]; then
  force=1
  shift
fi
old="${1:-}"
new="${2:-HEAD}"

needs_reenable=$force
if [[ $force -eq 0 && -n "$old" ]] && git rev-parse -q --verify "$old" >/dev/null; then
  if git diff --name-only "$old" "$new" -- plugin.toml translations/ | grep -q .; then
    needs_reenable=1
  fi
fi

# Captured first: `grep -q` exits early, which pipefail would report as failure.
installed="$(noctalia msg plugins list 2>/dev/null || true)"
if ! grep -q "^$PLUGIN_ID .* enabled" <<<"$installed"; then
  exit 0 # installed but switched off: respect that
fi

if [[ $needs_reenable -eq 1 ]]; then
  noctalia msg plugins disable "$PLUGIN_ID" >/dev/null
  sleep 1
  noctalia msg plugins enable "$PLUGIN_ID" >/dev/null
  echo "headroom: manifest or translations changed; plugin re-enabled"
else
  echo "headroom: code hot-reloads; nothing else to do"
fi
