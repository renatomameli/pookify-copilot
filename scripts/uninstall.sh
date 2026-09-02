#!/bin/bash
# Removes Pookify Copilot: deletes its owned Copilot hook file, quits the app,
# and deletes it from /Applications.
set -euo pipefail

APP_DST="/Applications/Pookify Copilot.app"
LOCAL_APP="$(cd "$(dirname "$0")/.." && pwd)/build/Pookify Copilot.app"
SUPPORT_DIR="$HOME/Library/Application Support/Pookify Copilot"
PID_FILE="$SUPPORT_DIR/app.pid"
INSTALL_LOCK="$SUPPORT_DIR/installing"

mkdir -p "$SUPPORT_DIR"
touch "$INSTALL_LOCK"
cleanup_lock() { rm -f "$INSTALL_LOCK"; }
trap cleanup_lock EXIT INT TERM

echo "▸ Quitting app…"
osascript -e 'if application id "com.pookify.copilot" is running then tell application id "com.pookify.copilot" to quit' \
  >/dev/null 2>&1 || true
if [[ -f "$PID_FILE" ]]; then
  app_pid="$(tr -dc '0-9' < "$PID_FILE")"
  app_command=""
  if [[ "$app_pid" =~ ^[1-9][0-9]*$ ]]; then
    read -r app_command < <(ps -p "$app_pid" -o comm= 2>/dev/null || true) || true
  fi
  if [[ "$app_command" == */PookifyCopilot ]]; then
    kill "$app_pid"
  fi
fi

echo "▸ Removing hooks…"
if [[ -x "$APP_DST/Contents/MacOS/PookifyCopilot" ]]; then
  "$APP_DST/Contents/MacOS/PookifyCopilot" --uninstall
elif [[ -x "$LOCAL_APP/Contents/MacOS/PookifyCopilot" ]]; then
  "$LOCAL_APP/Contents/MacOS/PookifyCopilot" --uninstall
fi

echo "▸ Removing app…"
rm -rf "$APP_DST"

cleanup_lock
trap - EXIT INT TERM

echo "✓ Pookify Copilot uninstalled."
