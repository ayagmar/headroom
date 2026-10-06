#!/usr/bin/env bash
# Copies what Noctalia loads (code, translations, README, images) into a
# community-plugins checkout as <dest>/headroom/. Tests and dev tooling stay in
# this repository.
# Usage: scripts/stage.sh ~/Projects/noctalia-community-plugins
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
checkout="$(cd "${1:?usage: scripts/stage.sh <community-plugins checkout>}" && pwd)"
dest="$checkout/headroom"
rm -rf "$dest"
mkdir -p "$dest"
cd "$root"
cp -r plugin.toml README.md LICENSE thumbnail.webp screenshot.png settings.png \
  service.luau bar.luau panel.luau lib ui providers translations "$dest/"
echo "Staged $(find "$dest" -type f | wc -l) files into $dest"
