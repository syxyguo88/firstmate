#!/usr/bin/env bash
# Behavior and tracked-registration tests for the native session-start nudge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

TMP_ROOT=$(fm_test_tmproot fm-sessionstart-nudge)
NUDGE="$ROOT/bin/fm-sessionstart-nudge.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"
NUDGE_TEXT="Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions."
fm_operational_input_encode session-start "$NUDGE_TEXT" NUDGE_LINE \
  || fail "could not construct expected session-start nudge"
fm_git_identity fmtest fmtest@example.invalid

make_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

run_nudge() {
  local root=$1
  FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
}

run_cursor_nudge() {
  local root=$1 payload=$2
  printf '%s' "$payload" | FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" \
    FM_HOME="$root" "$NUDGE" --cursor
}

expect_silent_zero() {
  local label=$1
  shift
  local out status=0
  out=$("$@" 2>&1) || status=$?
  expect_code 0 "$status" "$label must exit 0"
  [ -z "$out" ] || fail "$label must be silent, got: $out"
}

test_genuine_primary_nudges() {
  local root="$TMP_ROOT/primary" out prefix_hex status=0
  make_primary "$root"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "genuine primary nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "genuine primary printed unexpected output: $out"
  prefix_hex=$(printf '%s' "$out" | head -c 3 | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a3 ] || fail "genuine primary nudge lost its U+2063 operational marker: $prefix_hex"
  pass "fm-sessionstart-nudge: a genuine primary gets one explicitly marked instruction line"
}

test_cursor_primary_returns_native_context_json() {
  local root="$TMP_ROOT/cursor-primary" out payload status=0
  make_primary "$root"
  payload='{"hook_event_name":"sessionStart","cursor_version":"2.1.0","session_id":"cursor-session","is_background_agent":false,"composer_mode":"agent"}'
  out=$(run_cursor_nudge "$root" "$payload") || status=$?
  expect_code 0 "$status" "Cursor primary sessionStart nudge"
  printf '%s' "$out" | jq -e --arg expected "$NUDGE_LINE" '
    (keys == ["additional_context"]) and .additional_context == $expected
  ' >/dev/null || fail "Cursor sessionStart output must decode exactly to the operational nudge: $out"
  pass "fm-sessionstart-nudge --cursor: native JSON carries the exact operational nudge"
}

test_cursor_malformed_and_wrong_event_fail_open() {
  local root="$TMP_ROOT/cursor-invalid" payload
  make_primary "$root"
  for payload in \
    '{not-json' \
    '{}' \
    '{"hook_event_name":"SessionStart","cursor_version":"2.1.0","session_id":"s","is_background_agent":false}' \
    '{"hook_event_name":"sessionStart","session_id":"s","is_background_agent":false}' \
    '{"hook_event_name":"sessionStart","cursor_version":"2.1.0","session_id":7,"is_background_agent":false}' \
    '{"hook_event_name":"sessionStart","cursor_version":"2.1.0","session_id":"s","is_background_agent":"false"}'
  do
    expect_silent_zero "invalid Cursor sessionStart payload" \
      run_cursor_nudge "$root" "$payload"
  done
  pass "fm-sessionstart-nudge --cursor: malformed and non-sessionStart payloads fail open silently"
}

test_cursor_scope_keeps_worker_inert_and_secondmate_active() {
  local base="$TMP_ROOT/cursor-scope-base" worker="$TMP_ROOT/cursor-worker"
  local second="$TMP_ROOT/cursor-secondmate" payload out status=0
  fm_git_worktree "$base" "$worker" fm/cursor-sessionstart-worker
  mkdir -p "$worker/bin" "$worker/state"
  : > "$worker/AGENTS.md"
  payload='{"hook_event_name":"sessionStart","cursor_version":"2.1.0","session_id":"scope","is_background_agent":false}'
  expect_silent_zero "Cursor linked worker nudge" run_cursor_nudge "$worker" "$payload"

  git -C "$base" worktree add --quiet -b fm/cursor-sessionstart-secondmate "$second"
  mkdir -p "$second/bin" "$second/state"
  : > "$second/AGENTS.md"
  printf 'cursor-sm\n' > "$second/.fm-secondmate-home"
  out=$(run_cursor_nudge "$second" "$payload") || status=$?
  expect_code 0 "$status" "Cursor secondmate sessionStart nudge"
  printf '%s' "$out" | jq -e --arg expected "$NUDGE_LINE" \
    '.additional_context == $expected' >/dev/null \
    || fail "Cursor secondmate primary did not receive native context JSON: $out"
  pass "fm-sessionstart-nudge --cursor: linked worker is inert and marked secondmate primary is active"
}

test_claude_mode_suppresses_only_native_cursor_fingerprint() {
  local root="$TMP_ROOT/claude-duplicate" payload out status
  make_primary "$root"
  for payload in \
    '{"hook_event_name":"sessionStart","cursor_version":"2.1.0"}' \
    '{"cursor_version":"2.1.0"}' \
    '{"hook_event_name":"damaged","cursor_version":"2.1.0"}'
  do
    status=0
    out=$(printf '%s' "$payload" \
      | FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
        "$NUDGE" --claude 2>&1) || status=$?
    expect_code 0 "$status" "Claude compatibility hook on Cursor-versioned payload"
    [ -z "$out" ] || fail "--claude must suppress complete or partial Cursor payloads: $out"
  done

  status=0
  out=$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' \
    | CURSOR_AGENT=1 FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$root" "$NUDGE" --claude 2>&1) || status=$?
  expect_code 0 "$status" "ordinary Claude sessionStart payload"
  [ "$out" = "$NUDGE_LINE" ] \
    || fail "--claude must preserve raw output when CURSOR_AGENT alone is set: $out"
  pass "fm-sessionstart-nudge --claude: any Cursor-versioned object is silent without trusting event name or CURSOR_AGENT"
}

test_claude_registration_selects_claude_mode() {
  local command
  command=$(jq -r '.hooks.SessionStart[0].hooks[0].command // empty' \
    "$ROOT/.claude/settings.json")
  assert_contains "$command" 'fm-sessionstart-nudge.sh --claude' \
    "Claude SessionStart registration must select the raw Claude adapter mode"
  pass ".claude settings: SessionStart explicitly selects --claude"
}

test_gate_env_is_silent() {
  local root="$TMP_ROOT/gate-env"
  make_primary "$root"
  expect_silent_zero "gate env nudge" env NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
  pass "fm-sessionstart-nudge: NO_MISTAKES_GATE is silent"
}

test_gate_common_dir_is_silent() {
  local source="$TMP_ROOT/gate-source" bare="$TMP_ROOT/.no-mistakes/repos/gate.git"
  local root="$TMP_ROOT/gate-worktree"
  fm_git_init_commit "$source"
  mkdir -p "$(dirname "$bare")"
  git clone --quiet --bare "$source" "$bare"
  git --git-dir="$bare" worktree add --quiet -b gate-test "$root" HEAD
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'gate-test\n' > "$root/.fm-secondmate-home"
  expect_silent_zero "gate common-dir nudge" env FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
  pass "fm-sessionstart-nudge: .no-mistakes gate common-dir is silent"
}

test_unmarked_linked_worktree_is_silent() {
  local base="$TMP_ROOT/worktree-base" root="$TMP_ROOT/worktree-child"
  fm_git_worktree "$base" "$root" fm/sessionstart-linked
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  expect_silent_zero "linked worktree nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: an unmarked linked task worktree is silent"
}

test_linked_secondmate_primary_nudges() {
  local base="$TMP_ROOT/secondmate-base" root="$TMP_ROOT/secondmate-home" out status=0
  fm_git_worktree "$base" "$root" fm/sessionstart-secondmate
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'sessionstart-sm\n' > "$root/.fm-secondmate-home"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "linked secondmate nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "linked secondmate printed unexpected output: $out"
  pass "fm-sessionstart-nudge: a marked linked secondmate home is a primary"
}

test_missing_state_is_silent() {
  local root="$TMP_ROOT/missing-state"
  make_primary "$root"
  rmdir "$root/state"
  expect_silent_zero "missing state nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: a checkout without state is silent"
}

test_owned_lock_is_silent() {
  local root="$TMP_ROOT/already-ran"
  make_primary "$root"
  printf '%s\n' "$$" > "$root/state/.lock"
  expect_silent_zero "owned lock nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: a lock holder in process ancestry is already run"
}

test_opencode_plugin_delivers_exact_nudge_once() {
  local root="$TMP_ROOT/opencode-primary" out status=0
  make_primary "$root"
  cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-gate-refuse-lib.sh" "$ROOT/bin/fm-operational-input.sh" "$root/bin/"
  chmod +x "$root/bin/fm-sessionstart-nudge.sh"
  out=$(PLUGIN="$ROOT/.opencode/plugins/fm-primary-sessionstart-nudge.js" \
    WORKTREE="$root" EXPECTED="$NUDGE_LINE" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const hooks = await mod.FmPrimarySessionstartNudge({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = {
  type: "session.created",
  properties: { sessionID: "session-nudge-test", info: { id: "session-nudge-test" } },
};
await hooks.event({ event });
await hooks.event({ event });
if (prompts.length !== 1) throw new Error(`expected one prompt, got ${prompts.length}`);
if (prompts[0] !== process.env.EXPECTED) throw new Error(`unexpected prompt: ${prompts[0]}`);
EOF
  ) || status=$?
  expect_code 0 "$status" "OpenCode exact nudge delivery"
  [ -z "$out" ] || fail "OpenCode exact nudge delivery printed output: $out"
  pass "OpenCode session.created delivers the exact wrapper nudge once per session"
}

test_genuine_primary_nudges
test_cursor_primary_returns_native_context_json
test_cursor_malformed_and_wrong_event_fail_open
test_cursor_scope_keeps_worker_inert_and_secondmate_active
test_claude_mode_suppresses_only_native_cursor_fingerprint
test_claude_registration_selects_claude_mode
test_gate_env_is_silent
test_gate_common_dir_is_silent
test_unmarked_linked_worktree_is_silent
test_linked_secondmate_primary_nudges
test_missing_state_is_silent
test_owned_lock_is_silent
test_opencode_plugin_delivers_exact_nudge_once
