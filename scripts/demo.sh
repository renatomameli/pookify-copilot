#!/bin/bash
# Pookify Copilot demo harness
#
# Preview states with fake Copilot sessions in an isolated support directory. This never installs
# or edits hooks.
#
# Usage:
#   ./scripts/demo.sh <activity>
#   ./scripts/demo.sh story
#   ./scripts/demo.sh multi [2-30]
#   ./scripts/demo.sh open|close|blink|finish|cycle
#   ./scripts/demo.sh stop
#
# Activities:
#   thinking reading searching running editing writing websearch webfetch
#   planning delegating mcp asking compacting working permission input done error
#
# Options:
#   EXPAND=1              keep the drop-down open
#   SHADE=<0..1 | #hex>   override the pill color
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="$(pwd)"
DEMO_ROOT="$HOME/Library/Application Support/Pookify Copilot Demo"
SD="$DEMO_ROOT/state.d"
RUN="$DEMO_ROOT/.demo"
APP="$REPO/.build/debug/PookifyCopilot"
mkdir -p "$SD" "$RUN"

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

pid_alive() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

stop_pid_file() {
  local file="$1" pid=""
  [[ -f "$file" ]] && pid="$(<"$file")"
  if pid_alive "$pid"; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$file"
}

live_pid() {
  local key="${1:-default}" file pid=""
  file="$RUN/session-$key.pid"
  [[ -f "$file" ]] && pid="$(<"$file")"
  if ! pid_alive "$pid"; then
    nohup sleep 100000 >/dev/null 2>&1 &
    pid=$!
    printf '%s\n' "$pid" > "$file"
  fi
  printf '%s' "$pid"
}

app_running() {
  local file="$DEMO_ROOT/app.pid" pid=""
  [[ -f "$file" ]] && pid="$(<"$file")"
  pid_alive "$pid"
}

ensure_app() {
  app_running && return
  if [[ ! -x "$APP" ]]; then
    echo "Building..."
    swift build >/dev/null
  fi
  ISLAND_SUPPORT_DIR="$DEMO_ROOT" \
  ISLAND_NO_INSTALL=1 \
  ISLAND_PILL="${SHADE:-}" \
  ISLAND_FORCE_EXPAND="${EXPAND:-}" \
  nohup "$APP" >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$RUN/launched-app.pid"
  sleep 0.6
}

clear_states() {
  rm -f "$SD"/copilot-*.json
}

# write_state <id> <project> <state> <label> <tool> <started-at> [detail]
write_state() {
  local id="$1" project="$2" state="$3" label="$4" tool="$5" started_at="$6"
  local detail="${7:-}" now pid
  now="$(date +%s)"
  pid="$(live_pid "$id")"
  printf '{"schema":2,"provider":"copilot","sessionId":"%s","state":"%s","label":"%s","tool":"%s","project":"%s","cwd":"%s","pid":%s,"startedAt":%s,"ts":%s,"toolEndsAt":0,"detail":"%s"}\n' \
    "$id" "$state" "$label" "$tool" "$project" "$(json_escape "$REPO")" \
    "$pid" "$started_at" "$now" "$detail" > "$SD/copilot-$id.json"
}

resolve() {
  local activity="$1"
  STATE=tool LABEL="" TOOL="" AGO=12 DETAIL=""
  case "$activity" in
    thinking)   STATE=thinking; LABEL="Thinking..."; TOOL=""; AGO=8 ;;
    reading)    LABEL="Reading"; TOOL=view; DETAIL="sidebar.tsx" ;;
    searching)  LABEL="Searching"; TOOL=rg ;;
    running)    LABEL="Running command"; TOOL=bash; AGO=72 ;;
    editing)    LABEL="Editing"; TOOL=edit; AGO=45; DETAIL="AppController.swift" ;;
    writing)    LABEL="Writing"; TOOL=create; AGO=20; DETAIL="NewFile.swift" ;;
    websearch)  LABEL="Searching web"; TOOL=web_search ;;
    webfetch)   LABEL="Browsing web"; TOOL=web_fetch ;;
    planning)   LABEL="Planning"; TOOL=update_todo ;;
    delegating) LABEL="Delegating"; TOOL=task; AGO=30 ;;
    mcp)        LABEL="Using MCP tool"; TOOL=mcp_server_tool ;;
    asking)     LABEL="Asking a question"; TOOL=ask_user ;;
    compacting) LABEL="Compacting..."; TOOL=compact ;;
    working)    LABEL="Working..."; TOOL=custom_tool ;;
    permission) STATE=permission; LABEL="Awaiting permission"; TOOL=bash ;;
    input)      STATE=permission; LABEL="Input requested"; TOOL=ask_user ;;
    "done")     STATE="done"; LABEL="Done"; TOOL=""; AGO=0 ;;
    error)      STATE=error; LABEL="Error"; TOOL=""; AGO=0 ;;
    *) return 1 ;;
  esac
}

show() {
  local activity="$1" now started
  resolve "$activity" || {
    echo "Unknown activity '$activity'. Run './scripts/demo.sh help'." >&2
    exit 1
  }
  now="$(date +%s)"
  started=0
  (( AGO > 0 )) && started=$((now - AGO))
  clear_states
  write_state demo pookify-copilot "$STATE" "$LABEL" "$TOOL" "$started" "$DETAIL"
  ensure_app
  echo "Pookify Copilot: $activity -> $LABEL"
}

play_story() {
  local start
  echo -n "Starting in 3"; sleep 1
  echo -n " ... 2"; sleep 1
  echo -n " ... 1"; sleep 1
  echo " ... go"
  start="$(date +%s)"
  clear_states
  write_state demo pookify-copilot thinking "Thinking..." "" "$start"
  ensure_app
  sleep 3
  write_state demo pookify-copilot tool Reading view "$start" "README.md"
  sleep 3
  write_state demo pookify-copilot tool Editing edit "$start" "HookInstaller.swift"
  sleep 3
  write_state demo pookify-copilot permission "Awaiting permission" bash "$start"
  sleep 4
  write_state demo pookify-copilot tool "Running command" bash "$start"
  sleep 3
  write_state demo pookify-copilot "done" "Done" "" 0
  sleep 2.5
  clear_states
  echo "Story finished."
}

show_multi() {
  local count="${1:-4}" now pid i project state label tool ago detail
  [[ "$count" =~ ^[0-9]+$ ]] || {
    echo "usage: ./scripts/demo.sh multi [2-30]" >&2
    exit 1
  }
  (( count < 2 )) && count=2
  (( count > 30 )) && count=30
  now="$(date +%s)"
  clear_states

  for ((i = 0; i < count; i++)); do
    pid="$(live_pid "multi$i")"
    case $((i % 5)) in
      0) project="api-server"; state=tool; label=Editing; tool=edit; ago=45; detail="Routes.swift" ;;
      1) project="dashboard"; state=permission; label="Awaiting permission"; tool=bash; ago=130; detail="" ;;
      2) project="docs-site"; state=tool; label=Reading; tool=view; ago=18; detail="README.md" ;;
      3) project="release"; state=tool; label="Running command"; tool=bash; ago=320; detail="" ;;
      4) project="mobile-app"; state=thinking; label="Thinking..."; tool=""; ago=8; detail="" ;;
    esac
    printf '{"schema":2,"provider":"copilot","sessionId":"multi%s","state":"%s","label":"%s","tool":"%s","project":"%s","cwd":"%s","pid":%s,"startedAt":%s,"ts":%s,"toolEndsAt":0,"detail":"%s"}\n' \
      "$i" "$state" "$label" "$tool" "$project-$i" "$(json_escape "$REPO")" \
      "$pid" "$((now - ago))" "$now" "$detail" > "$SD/copilot-multi$i.json"
  done
  ensure_app
  echo "Pookify Copilot: $count fake sessions (permission first, then newest turns)."
}

register_driver() {
  printf '%s\n' "$$" > "$RUN/driver.pid"
  trap 'rm -f "$RUN/driver.pid"; exit 0' INT TERM
}

stop_demo() {
  local driver=""
  [[ -f "$RUN/driver.pid" ]] && driver="$(<"$RUN/driver.pid")"
  if pid_alive "$driver" && [[ "$driver" != "$$" ]]; then
    kill "$driver" 2>/dev/null || true
  fi
  stop_pid_file "$RUN/launched-app.pid"
  for session_pid_file in "$RUN"/session-*.pid; do
    [[ -e "$session_pid_file" ]] || continue
    stop_pid_file "$session_pid_file"
  done
  rm -rf "${DEMO_ROOT:?}"
  echo "Demo stopped."
}

ACTIVITIES=(
  thinking reading searching running editing writing websearch webfetch planning
  delegating mcp asking compacting working permission input "done" error
)

case "${1:-help}" in
  help|-h|--help)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    ;;
  stop)
    stop_demo
    ;;
  story)
    play_story
    ;;
  multi)
    show_multi "${2:-4}"
    ;;
  open)
    clear_states
    ensure_app
    show thinking
    ;;
  close)
    clear_states
    echo "Island retracting."
    ;;
  blink)
    register_driver
    ensure_app
    while true; do show thinking; sleep 3; clear_states; sleep 2.5; done
    ;;
  finish)
    register_driver
    ensure_app
    while true; do show running; sleep 3; show "done"; sleep 2.5; clear_states; sleep 2.5; done
    ;;
  cycle)
    register_driver
    ensure_app
    while true; do
      for activity in "${ACTIVITIES[@]}"; do show "$activity"; sleep 2.6; done
      clear_states
      sleep 1.5
    done
    ;;
  copilot)
    show "${2:-thinking}"
    ;;
  *)
    show "$1"
    ;;
esac
