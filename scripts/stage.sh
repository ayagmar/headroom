#!/usr/bin/env bash
# Copies the shippable plugin into a community-plugins checkout as <dest>/headroom/.
# Usage: scripts/stage.sh ~/Projects/noctalia-community-plugins
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="${1:?usage: scripts/stage.sh <community-plugins checkout>}/headroom"
mkdir -p "$dest"
rsync -a --delete \
  --exclude '.git/' --exclude '.gitignore' --exclude '.githooks/' --exclude '.tools/' --exclude 'tests/_generated/' \
  --exclude 'noctalia.d.luau' --exclude '*.tmp' \
  "$root/" "$dest/"
echo "Staged $(find "$dest" -type f | wc -l) files into $dest"
