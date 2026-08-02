#!/usr/bin/env bash
# Behavior tests for Cursor harness detection and session-lock identity.
# Cursor's official `agent` command is accepted only when its inherited marker
# accompanies an explicit cursor-agent executable identity; exact cursor-agent
# processes and the legacy Node index.js shape remain independently detectable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
LOCK_LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Keep the fake ancestry authoritative regardless of the harness running this
# suite. Each individual case opts into only the marker it is proving.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT
unset CURSOR_AGENT CURSOR_INVOKED_AS

cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done

shape=${FM_TEST_PS_SHAPE:?}
if [ "$pid" = 4100 ]; then
  case "$shape:$field" in
    native:comm=) printf '%s\n' '/Users/test/.local/share/cursor-agent/versions/2026.07.23-e383d2b/cursor-agent' ;;
    native:args=) printf '%s\n' '/Users/test/.local/bin/cursor-agent --use-system-ca /Users/test/.local/share/cursor-agent/versions/2026.07.23-e383d2b/index.js' ;;
    legacy-node:comm=) printf '%s\n' '/usr/local/bin/node' ;;
    legacy-node:args=) printf '%s\n' '/usr/local/bin/node /Users/test/.local/share/cursor-agent/versions/2026.06.01-old/index.js' ;;
    official-agent:comm=) printf '%s\n' '/Users/test/.local/bin/agent' ;;
    official-agent:args=) printf '%s\n' '/Users/test/.local/bin/agent --use-system-ca /Users/test/.local/share/cursor-agent/versions/2026.07.23-e383d2b/index.js' ;;
    official-agent-no-ca:comm=) printf '%s\n' '/Users/test/.local/bin/agent' ;;
    official-agent-no-ca:args=) printf '%s\n' '/Users/test/.local/bin/agent /Users/test/.local/share/cursor-agent/versions/2026.07.23-e383d2b/index.js' ;;
    agent-late-path:comm=) printf '%s\n' '/Users/test/.local/bin/agent' ;;
    agent-late-path:args=) printf '%s\n' '/Users/test/.local/bin/agent --inspect /Users/test/.local/share/cursor-agent/versions/2026.07.23-e383d2b/index.js' ;;
    plain-agent:comm=) printf '%s\n' '/usr/local/bin/agent' ;;
    plain-agent:args=) printf '%s\n' 'agent --serve' ;;
    helper:comm=) printf '%s\n' '/Users/test/.local/bin/cursor-agent-helper' ;;
    helper:args=) printf '%s\n' 'cursor-agent-helper --serve' ;;
    gui:comm=) printf '%s\n' '/Applications/Cursor.app/Contents/MacOS/Cursor' ;;
    gui:args=) printf '%s\n' '/Applications/Cursor.app/Contents/MacOS/Cursor --unity-launch' ;;
    generic-node:comm=) printf '%s\n' '/usr/local/bin/node' ;;
    generic-node:args=) printf '%s\n' '/usr/local/bin/node /tmp/cursor-agent-helper/index.js' ;;
    node-late-path:comm=) printf '%s\n' '/usr/local/bin/node' ;;
    node-late-path:args=) printf '%s\n' '/usr/local/bin/node /tmp/app.js /Users/test/.local/share/cursor-agent/versions/v/index.js' ;;
    incomplete-version-path:comm=) printf '%s\n' '/usr/local/bin/node' ;;
    incomplete-version-path:args=) printf '%s\n' '/usr/local/bin/node /Users/test/.local/share/cursor-agent/versions/2026.07.23-e383d2b/helper.js' ;;
    marker-codex:comm=) printf '%s\n' '/opt/test/bin/codex' ;;
    marker-codex:args=) printf '%s\n' 'codex' ;;
    marker-claude:comm=) printf '%s\n' '/opt/test/bin/claude' ;;
    marker-claude:args=) printf '%s\n' 'claude' ;;
    *:ppid=) printf '%s\n' 1 ;;
    *) exit 1 ;;
  esac
  exit 0
fi

case "$field" in
  comm=) printf '%s\n' '/bin/bash' ;;
  args=) printf '%s\n' 'bash tests/fm-cursor-harness.test.sh' ;;
  ppid=) printf '%s\n' 4100 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/ps"

cursor_env() {
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS "$@"
}

detect_shape() {
  local shape=$1
  shift
  cursor_env FM_TEST_PS_SHAPE="$shape" PATH="$FAKEBIN:$BASE_PATH" \
    "$@" "$ROOT/bin/fm-harness.sh"
}

ancestry_shape() {
  local shape=$1
  shift
  cursor_env FM_TEST_PS_SHAPE="$shape" PATH="$FAKEBIN:$BASE_PATH" \
    "$@" bash -c '. "$1"; fm_harness_ancestry_pid' _ "$LOCK_LIB"
}

alive_shape() {
  local shape=$1 pid=$2
  shift 2
  cursor_env FM_TEST_PS_SHAPE="$shape" PATH="$FAKEBIN:$BASE_PATH" \
    "$@" bash -c '. "$1"; kill() { return 0; }; fm_harness_pid_alive "$2"' \
    _ "$LOCK_LIB" "$pid"
}

owned_shape() {
  local shape=$1 state=$2
  shift 2
  cursor_env FM_TEST_PS_SHAPE="$shape" PATH="$FAKEBIN:$BASE_PATH" \
    "$@" bash -c '. "$1"; fm_session_lock_owned_by_self "$2"' \
    _ "$LOCK_LIB" "$state"
}

test_native_cursor_agent_identity() {
  local got state
  got=$(detect_shape native)
  [ "$got" = cursor ] || fail "native cursor-agent resolved '$got', expected cursor"
  got=$(ancestry_shape native) || fail "session-lock ancestry rejected native cursor-agent"
  [ "$got" = 4100 ] || fail "native cursor-agent ancestry selected '$got', expected stable pid 4100"
  alive_shape native 4100 || fail "session-lock liveness rejected native cursor-agent pid"

  state="$TMP_ROOT/native-state"
  mkdir -p "$state"
  printf '%s\n' 4100 > "$state/.lock"
  owned_shape native "$state" || fail "session-lock ownership rejected the selected native cursor-agent pid"
  pass "Cursor identity: native cursor-agent drives detection and exact session-lock ownership"
}

test_legacy_node_identity() {
  local got
  got=$(detect_shape legacy-node)
  [ "$got" = cursor ] || fail "legacy Cursor Node process resolved '$got', expected cursor"
  got=$(ancestry_shape legacy-node) || fail "session-lock ancestry rejected legacy Cursor Node process"
  [ "$got" = 4100 ] || fail "legacy Cursor Node ancestry selected '$got', expected pid 4100"
  alive_shape legacy-node 4100 || fail "session-lock liveness rejected legacy Cursor Node pid"
  pass "Cursor identity: constrained versions/index.js ancestry preserves legacy Node compatibility"
}

test_official_agent_requires_marker_and_explicit_identity() {
  local shape got
  got=$(detect_shape official-agent CURSOR_AGENT=1 CURSOR_INVOKED_AS=agent)
  [ "$got" = cursor ] || fail "marked official agent resolved '$got', expected cursor"
  got=$(ancestry_shape official-agent CURSOR_AGENT=1 CURSOR_INVOKED_AS=agent) \
    || fail "session-lock ancestry rejected marked official agent"
  [ "$got" = 4100 ] || fail "official agent ancestry selected '$got', expected pid 4100"
  alive_shape official-agent 4100 CURSOR_AGENT=1 CURSOR_INVOKED_AS=agent \
    || fail "session-lock liveness rejected marked official agent pid"

  got=$(detect_shape official-agent)
  [ "$got" = unknown ] || fail "unmarked official agent resolved '$got', expected unknown"
  if ancestry_shape official-agent >/dev/null; then
    fail "current ancestry accepted unmarked process named agent"
  fi
  alive_shape official-agent 4100 \
    || fail "external liveness observer rejected explicit official cursor-agent identity without inheriting CURSOR_AGENT"

  shape=official-agent-no-ca
  got=$(detect_shape "$shape" CURSOR_AGENT=1 CURSOR_INVOKED_AS=agent)
  [ "$got" = cursor ] || fail "marked official agent fallback resolved '$got', expected cursor"
  got=$(ancestry_shape "$shape" CURSOR_AGENT=1 CURSOR_INVOKED_AS=agent) \
    || fail "session-lock ancestry rejected marked official agent fallback"
  [ "$got" = 4100 ] || fail "official agent fallback ancestry selected '$got', expected pid 4100"
  alive_shape "$shape" 4100 \
    || fail "external liveness observer rejected official agent fallback without inheriting CURSOR_AGENT"
  pass "Cursor identity: official agent accepts verified system-CA and fallback argv shapes"
}

test_cursor_lookalikes_are_rejected() {
  local shape got
  for shape in node-late-path agent-late-path plain-agent helper gui generic-node incomplete-version-path; do
    got=$(detect_shape "$shape" CURSOR_AGENT=1)
    [ "$got" = unknown ] || fail "$shape resolved '$got' with marker-only evidence, expected unknown"
    if ancestry_shape "$shape" CURSOR_AGENT=1 >/dev/null; then
      fail "session-lock ancestry accepted Cursor lookalike shape $shape"
    fi
    if alive_shape "$shape" 4100 CURSOR_AGENT=1; then
      fail "session-lock liveness accepted Cursor lookalike shape $shape"
    fi
  done
  pass "Cursor identity: agent/helper/GUI/generic Node lookalikes are rejected"
}

test_marker_only_does_not_steal_real_ancestry() {
  local got
  got=$(detect_shape marker-codex CURSOR_AGENT=1 CURSOR_INVOKED_AS=agent)
  [ "$got" = codex ] || fail "marker-only Cursor environment stole Codex ancestry as '$got'"
  got=$(ancestry_shape marker-codex CURSOR_AGENT=1 CURSOR_INVOKED_AS=agent) \
    || fail "session-lock ancestry lost the real Codex ancestor"
  [ "$got" = 4100 ] || fail "marker-only Codex ancestry selected '$got', expected pid 4100"

  got=$(detect_shape marker-claude CURSOR_AGENT=1 CURSOR_INVOKED_AS=agent)
  [ "$got" = claude ] || fail "marker-only Cursor environment stole Claude ancestry as '$got'"
  pass "Cursor identity: marker-only inheritance cannot outrank real Claude/Codex ancestry"
}

test_existing_marker_precedence_is_unchanged() {
  local got
  got=$(detect_shape native CLAUDECODE=1 CURSOR_AGENT=1)
  [ "$got" = claude ] || fail "CLAUDECODE precedence regressed: got '$got'"
  got=$(detect_shape native PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed CURSOR_AGENT=1)
  [ "$got" = pi-signed ] || fail "Pi marker precedence regressed: got '$got'"
  got=$(detect_shape native GROK_AGENT=1 CURSOR_AGENT=1)
  [ "$got" = grok ] || fail "GROK_AGENT precedence regressed: got '$got'"
  pass "Harness identity: existing Claude/Pi/Grok marker precedence remains unchanged"
}

test_runner_classifies_cursor_contract_suite() {
  local listed
  listed=$("$ROOT/bin/fm-test-run.sh" --list --family pure-contract-unit)
  assert_contains "$listed" "tests/fm-cursor-harness.test.sh" \
    "pure-contract-unit family must include the Cursor harness contract suite"
  pass "Test runner: Cursor harness contract suite is classified with pure contract tests"
}

test_native_cursor_agent_identity
test_legacy_node_identity
test_cursor_lookalikes_are_rejected
test_official_agent_requires_marker_and_explicit_identity
test_marker_only_does_not_steal_real_ancestry
test_existing_marker_precedence_is_unchanged
test_runner_classifies_cursor_contract_suite
