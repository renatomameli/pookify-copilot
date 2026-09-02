#!/bin/bash
# One-line build-from-source install. Builds the app, copies it to /Applications, wires up
# GitHub Copilot CLI hooks, and launches it. No Apple Developer account or notarization needed —
# a locally built app isn't quarantined, so Gatekeeper trusts it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_SRC="build/Pookify Copilot.app"
APP_DST="/Applications/Pookify Copilot.app"

echo "▸ Building…"
./scripts/build.sh

if [[ ! -w /Applications ]]; then
  echo "✗ Can't write to /Applications (it needs an administrator account)."
  echo "  The app was built at: $APP_SRC"
  echo "  Drag it into /Applications in Finder (you'll be asked to authenticate), then run:"
  echo "      \"/Applications/Pookify Copilot.app/Contents/MacOS/PookifyCopilot\" --install"
  echo "  (Don't 'sudo' this script — that would wire hooks into root's config, not yours.)"
  exit 1
fi

echo "▸ Installing to /Applications…"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "▸ Wiring hooks into GitHub Copilot CLI…"
"$APP_DST/Contents/MacOS/PookifyCopilot" --install

echo "▸ Launching…"
open "$APP_DST"

echo ""
echo "✓ Installed. Restart GitHub Copilot CLI, then start a session."
echo "  The island appears on your notch as soon as Copilot begins working."
