#!/bin/bash
# Removes Pookify Copilot: deletes its owned Copilot hook file, quits the app,
# and deletes it from /Applications.
set -euo pipefail

APP_DST="/Applications/Pookify Copilot.app"
LOCAL_APP="$(cd "$(dirname "$0")/.." && pwd)/build/Pookify Copilot.app"

echo "▸ Removing hooks…"
if [[ -x "$APP_DST/Contents/MacOS/PookifyCopilot" ]]; then
  "$APP_DST/Contents/MacOS/PookifyCopilot" --uninstall
elif [[ -x "$LOCAL_APP/Contents/MacOS/PookifyCopilot" ]]; then
  "$LOCAL_APP/Contents/MacOS/PookifyCopilot" --uninstall
fi

echo "▸ Quitting app…"
pkill -x PookifyCopilot 2>/dev/null || true

echo "▸ Removing app…"
rm -rf "$APP_DST"

echo "✓ Pookify Copilot uninstalled."
