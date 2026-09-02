#!/bin/bash
# One-line build-from-source install. Builds the app, copies it to /Applications, wires up
# GitHub Copilot CLI hooks, and launches it. No Apple Developer account or notarization needed —
# a locally built app isn't quarantined, so Gatekeeper trusts it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_SRC="build/Pookify Copilot.app"
APP_DST="/Applications/Pookify Copilot.app"
SUPPORT_DIR="$HOME/Library/Application Support/Pookify Copilot"
PID_FILE="$SUPPORT_DIR/app.pid"
INSTALL_LOCK="$SUPPORT_DIR/installing"

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

mkdir -p "$SUPPORT_DIR"
touch "$INSTALL_LOCK"
chmod 600 "$INSTALL_LOCK"
cleanup_lock() { rm -f "$INSTALL_LOCK"; }
trap cleanup_lock EXIT INT TERM

echo "▸ Stopping the previous version…"
osascript -e 'if application id "com.pookify.copilot" is running then tell application id "com.pookify.copilot" to quit' \
  >/dev/null 2>&1 || true
for _ in {1..30}; do
  running="$(osascript -e 'application id "com.pookify.copilot" is running' 2>/dev/null || echo false)"
  [[ "$running" != "true" ]] && break
  sleep 0.1
done
if [[ -f "$PID_FILE" ]]; then
  old_pid="$(tr -dc '0-9' < "$PID_FILE")"
  old_command=""
  if [[ "$old_pid" =~ ^[1-9][0-9]*$ ]]; then
    read -r old_command < <(ps -p "$old_pid" -o comm= 2>/dev/null || true) || true
  fi
  if [[ "$old_command" == */PookifyCopilot ]]; then
    kill "$old_pid"
    for _ in {1..20}; do
      kill -0 "$old_pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
fi
rm -f "$PID_FILE"

echo "▸ Installing to /Applications…"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "▸ Wiring hooks into GitHub Copilot CLI…"
"$APP_DST/Contents/MacOS/PookifyCopilot" --install

cleanup_lock
trap - EXIT INT TERM

echo "▸ Launching…"
open -g -n "$APP_DST"

echo ""
echo "✓ Installed. Restart GitHub Copilot CLI, then start a session."
echo "  The island appears on your notch as soon as Copilot begins working."
