#!/bin/bash
# Smoke-tests the assembled app, generated Copilot hook file, and helper state transitions.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_BUNDLE="$PWD/build/Pookify Copilot.app"
APP="$APP_BUNDLE/Contents/MacOS/PookifyCopilot"
if [[ ! -x "$APP" ]] \
  || find Sources Package.swift scripts/build.sh -type f -newer "$APP" -print -quit | grep -q .; then
  ./scripts/build.sh
fi

fail() {
  echo "test failed: $*" >&2
  exit 1
}

assert_equal() {
  local actual="$1" expected="$2" description="$3"
  [[ "$actual" == "$expected" ]] || {
    fail "$description (expected '$expected', got '$actual')"
  }
}

tmp_base="${TMPDIR:-/tmp}"
root="$(mktemp -d "$tmp_base/pookify-copilot.XXXXXX")"
idle_pid=""
done_pid=""
cleanup() {
  if [[ "$idle_pid" =~ ^[0-9]+$ ]]; then
    kill "$idle_pid" 2>/dev/null || true
    wait "$idle_pid" 2>/dev/null || true
  fi
  if [[ "$done_pid" =~ ^[0-9]+$ ]]; then
    kill "$done_pid" 2>/dev/null || true
    wait "$done_pid" 2>/dev/null || true
  fi
  rm -rf "${root:?}"
}
trap cleanup EXIT
mkdir -p "$root/copilot"

COPILOT_HOME="$root/copilot" ISLAND_SUPPORT_DIR="$root/support" "$APP" --install >/dev/null

config="$root/copilot/hooks/pookify-copilot.json"
jq -e . "$config" >/dev/null || fail "generated hook file is not valid JSON"
for event in sessionStart sessionEnd userPromptSubmitted preToolUse postToolUse \
  postToolUseFailure agentStop errorOccurred subagentStart subagentStop preCompact notification; do
  jq -e --arg event "$event" '.hooks[$event] | length == 1' "$config" >/dev/null \
    || fail "missing $event hook"
done
jq -e '.hooks.preToolUse[0].bash | endswith("|| true")' "$config" >/dev/null \
  || fail "preToolUse hook is not fail open"
jq -e '.hooks.notification[0].matcher == "permission_prompt|elicitation_dialog"' \
  "$config" >/dev/null || fail "notification hook matcher is incorrect"
jq -e '.hooks.permissionRequest == null' "$config" >/dev/null \
  || fail "permissionRequest must not be installed"

helper="$root/support/bin/island-hook"
state="$root/support/state.d/copilot-integration.json"
export ISLAND_SUPPORT_DIR="$root/support"
export ISLAND_NO_LAUNCH=1

session_command="$(jq -r '.hooks.sessionStart[0].bash' "$config")"
printf '%s' '{"sessionId":"integration","cwd":"/tmp/project"}' \
  | /bin/bash -c "$session_command"
assert_equal "$(jq -r .state "$state")" idle "generated shell command"
[[ "$(jq -r .pid "$state")" =~ ^[1-9][0-9]*$ ]] || fail "generated command did not record a session pid"

pre_command="$(jq -r '.hooks.preToolUse[0].bash' "$config")"
mv "$helper" "$helper.disabled"
if ! printf '%s' '{"sessionId":"missing-helper","toolName":"bash"}' \
  | /bin/bash -c "$pre_command" 2>/dev/null; then
  mv "$helper.disabled" "$helper"
  fail "preToolUse command failed closed when the helper was missing"
fi
mv "$helper.disabled" "$helper"

send() {
  local kind="$1" payload="$2"
  printf '%s' "$payload" | "$helper" copilot "$kind"
}

export COPILOT_SESSION_PID=$$
send unknown 'not json'
old_state="$root/support/state.d/copilot-old-session.json"
send session-start '{"sessionId":"old-session","cwd":"/tmp/project"}'
[[ -e "$old_state" ]] || fail "old session fixture was not created"
send session-start '{"sessionId":"integration","cwd":"/tmp/project"}'
assert_equal "$(jq -r .state "$state")" idle "sessionStart state"
[[ ! -e "$old_state" ]] || fail "sessionStart did not remove an older session for the same process"

send prompt '{"sessionId":"integration","cwd":"/tmp/project"}'
assert_equal "$(jq -r .state "$state")" thinking "prompt state"

send pre '{"sessionId":"integration","cwd":"/tmp/project","toolName":"edit","toolArgs":{"path":"/tmp/project/App.swift"}}'
assert_equal "$(jq -r .state "$state")" tool "preToolUse state"
assert_equal "$(jq -r .label "$state")" Editing "edit label"
assert_equal "$(jq -r .detail "$state")" App.swift "tool detail"

send notify '{"sessionId":"integration","cwd":"/tmp/project","notification_type":"permission_prompt"}'
assert_equal "$(jq -r .state "$state")" permission "permission notification state"
assert_equal "$(jq -r .label "$state")" "Awaiting permission" "permission label"

send post '{"sessionId":"integration","cwd":"/tmp/project","toolName":"edit"}'
assert_equal "$(jq -r .state "$state")" tool "postToolUse linger state"

send error '{"sessionId":"integration","cwd":"/tmp/project","recoverable":true}'
assert_equal "$(jq -r .label "$state")" "Recovering..." "recoverable error label"

send notify '{"sessionId":"integration","cwd":"/tmp/project","notification_type":"elicitation_dialog"}'
assert_equal "$(jq -r .label "$state")" "Input requested" "elicitation label"

send error '{"sessionId":"integration","cwd":"/tmp/project","recoverable":false}'
assert_equal "$(jq -r .state "$state")" error "non-recoverable error state"

event_ms="$((($(date +%s) + 5) * 1000))"
send prompt "{\"sessionId\":\"integration\",\"cwd\":\"/tmp/project\",\"timestamp\":$event_ms}"
send stop "{\"sessionId\":\"integration\",\"cwd\":\"/tmp/project\",\"timestamp\":$((event_ms - 1000))}"
assert_equal "$(jq -r .state "$state")" thinking "stale agentStop state"
send stop "{\"sessionId\":\"integration\",\"cwd\":\"/tmp/project\",\"timestamp\":$((event_ms + 1000))}"
assert_equal "$(jq -r .state "$state")" "done" "agentStop state"

send session-end "{\"sessionId\":\"integration\",\"cwd\":\"/tmp/project\",\"timestamp\":$((event_ms + 2000))}"
[[ ! -e "$state" ]] || fail "sessionEnd did not remove state"

aggregate_support="$root/aggregate-support"
sleep 30 &
idle_pid=$!
sleep 30 &
done_pid=$!
printf '%s' '{"sessionId":"idle-live","cwd":"/tmp/idle"}' \
  | COPILOT_SESSION_PID="$idle_pid" ISLAND_SUPPORT_DIR="$aggregate_support" \
    "$helper" copilot session-start
printf '%s' '{"sessionId":"done-live","cwd":"/tmp/done"}' \
  | COPILOT_SESSION_PID="$done_pid" ISLAND_SUPPORT_DIR="$aggregate_support" \
    "$helper" copilot session-start
printf '%s' '{"sessionId":"done-live","cwd":"/tmp/done"}' \
  | COPILOT_SESSION_PID="$done_pid" ISLAND_SUPPORT_DIR="$aggregate_support" \
    "$helper" copilot prompt
printf '%s' '{"sessionId":"done-live","cwd":"/tmp/done"}' \
  | COPILOT_SESSION_PID="$done_pid" ISLAND_SUPPORT_DIR="$aggregate_support" \
    "$helper" copilot stop

# A live idle Copilot process must remain selectable no matter how old its last hook event is.
idle_state="$aggregate_support/state.d/copilot-idle-live.json"
jq '.ts = now - 10800' "$idle_state" > "$idle_state.tmp"
mv "$idle_state.tmp" "$idle_state"

# In contrast, an old snapshot with no process identity is safe to reap.
orphan_state="$aggregate_support/state.d/copilot-orphan.json"
jq -n '{schema:2,provider:"copilot",sessionId:"orphan",state:"idle",label:"",
  tool:"",project:"",cwd:"",pid:0,startedAt:0,ts:(now-10800),toolEndsAt:0,detail:""}' \
  > "$orphan_state"

sessions="$(ISLAND_SUPPORT_DIR="$aggregate_support" "$APP" --dump-sessions)"
jq -e '
  length == 2
  and any(.[]; .id == "idle-live" and .state == "idle")
  and any(.[]; .id == "done-live" and .state == "done")
' <<< "$sessions" >/dev/null || fail "open idle session was omitted from aggregation"
[[ ! -e "$orphan_state" ]] || fail "expired pid-less snapshot was not reaped"

COPILOT_HOME="$root/copilot" ISLAND_SUPPORT_DIR="$root/support" "$APP" --uninstall >/dev/null
[[ ! -e "$config" ]] || fail "uninstall did not remove hook file"

plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null || fail "invalid Info.plist"
codesign --verify --deep --strict "$APP_BUNDLE" || fail "invalid app signature"

echo "Pookify Copilot smoke tests passed."
