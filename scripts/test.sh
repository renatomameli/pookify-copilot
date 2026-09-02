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
trap 'rm -rf "${root:?}"' EXIT
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

send unknown 'not json'
send session-start '{"sessionId":"integration","cwd":"/tmp/project"}'
assert_equal "$(jq -r .state "$state")" idle "sessionStart state"

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

send stop '{"sessionId":"integration","cwd":"/tmp/project"}'
assert_equal "$(jq -r .state "$state")" done "agentStop state"

send error '{"sessionId":"integration","cwd":"/tmp/project","recoverable":false}'
assert_equal "$(jq -r .state "$state")" error "non-recoverable error state"

send session-end '{"sessionId":"integration","cwd":"/tmp/project"}'
[[ ! -e "$state" ]] || fail "sessionEnd did not remove state"

COPILOT_HOME="$root/copilot" ISLAND_SUPPORT_DIR="$root/support" "$APP" --uninstall >/dev/null
[[ ! -e "$config" ]] || fail "uninstall did not remove hook file"

plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null || fail "invalid Info.plist"
codesign --verify --deep --strict "$APP_BUNDLE" || fail "invalid app signature"

echo "Pookify Copilot smoke tests passed."
