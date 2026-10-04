#!/usr/bin/env bash
# One-time setup to run Headroom from this checkout and keep it current:
#   - links the checkout into Noctalia's plugin directory and enables it
#   - points git at .githooks/, so every pull/checkout/rebase reloads the
#     running plugin when the manifest or translations changed
# Usage: scripts/dev-install.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
plugins="${XDG_DATA_HOME:-$HOME/.local/share}/noctalia/plugins"

mkdir -p "$plugins"
ln -sfn "$root" "$plugins/headroom"
current="$(git -C "$root" config --get core.hooksPath || true)"
if [[ -n "$current" && "$current" != ".githooks" ]]; then
  echo "core.hooksPath is already '$current'; leaving it. Run scripts/reload.sh after pulls instead."
else
  git -C "$root" config core.hooksPath .githooks
fi
chmod +x "$root"/.githooks/* "$root"/scripts/*.sh

if command -v noctalia >/dev/null 2>&1 && noctalia msg plugins list >/dev/null 2>&1; then
  noctalia msg plugins enable ayagmar/headroom >/dev/null
  echo "Enabled ayagmar/headroom. Add the Headroom widget from Settings → Bar."
else
  echo "Linked. Start Noctalia, then: noctalia msg plugins enable ayagmar/headroom"
fi
echo "git pull now reloads the plugin automatically (hooks: .githooks/)."
