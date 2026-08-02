#!/usr/bin/env bash
# Hermetic Cursor ACP runtime wiring tests. These exercise fm-spawn's real
# launch construction, semantic busy generation, existing fm-send terminal
# transport, and representative unchanged Claude/Codex launch contracts.
# No real Cursor agent, ACP server, terminal multiplexer, or model is started.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SPAWN="$ROOT/bin/fm-spawn.sh"
SEND="$ROOT/bin/fm-send.sh"
BRIDGE="$ROOT/bin/fm-cursor-acp-bridge.mjs"
TMP_ROOT=$(fm_test_tmproot fm-cursor-runtime)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}

assert_present "$BRIDGE" "Cursor ACP bridge is missing"
[ -x "$BRIDGE" ] || fail "Cursor ACP bridge must be directly executable"

cleanup_task_tmp() {
  local id=$1
  rm -rf "/tmp/fm-$id"
}

make_runtime_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'tmux'
  for arg in "$@"; do printf '\x1f%s' "$arg"; done
  printf '\n'
} >> "${FM_FAKE_TMUX_LOG:?}"
case "${1:-}" in
  has-session) exit 0 ;;
  list-windows)
    if [ "${FM_FAKE_CURSOR_PROCESS_TREE:-0}" = 1 ]; then
      printf '%s\n' fm-cursor-send fm-cursor-sm-send
    fi
    exit 0
    ;;
  new-window)
    printf '%s\n' '@42'
    exit 0
    ;;
  display-message)
    case "$*" in
      *pane_current_path*) printf '%s\n' "${FM_FAKE_PANE_PATH:-$PWD}" ;;
      *pane_current_command*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-fm-cursor-acp}" ;;
      *pane_pid*) printf '%s\n' 100 ;;
      *cursor_y*) printf '%s\n' 1 ;;
      *pane_id*) printf '%s\n' '%42' ;;
      *) printf '%s\n' firstmate ;;
    esac
    exit 0
    ;;
  capture-pane)
    case "$*" in
      *' -S 1 -E 1'*) printf '│    │\n' ;;
      *) printf '╭────╮\n│    │\n╰────╯\n' ;;
    esac
    exit 0
    ;;
  send-keys)
    literal=0
    value=
    last=
    for arg in "$@"; do last=$arg; done
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -l) literal=1; shift; value=${1:-}; break ;;
        *) shift ;;
      esac
    done
    if [ "$literal" = 0 ] && [ "$last" = Enter ] \
      && { [ "${FM_FAKE_TMUX_FAIL_LINE:-0}" = 1 ] || [ "${FM_FAKE_TMUX_FAIL_ENTER:-0}" = 1 ]; }; then
      exit 1
    fi
    if [ "$literal" = 1 ] && [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      printf '%s\n' "$value" >> "$FM_FAKE_LAUNCH_LOG"
    fi
    exit 0
    ;;
  set-window-option|new-session|kill-window) exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_CURSOR_PROCESS_TREE:-0}" = 1 ] && [ "$*" = "-axo pid=,ppid=,comm=,args=" ]; then
  printf '%s\n' \
    '100 1 zsh zsh' \
    '101 100 fm-cursor-acp node /firstmate/bin/fm-cursor-acp-bridge.mjs' \
    '102 101 agent agent --trust --force acp'
  exit 0
fi
exec /bin/ps "$@"
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/sleep" "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

setup_ship_world() {  # <name> <id>
  local name=$1 id=$2
  WORLD="$TMP_ROOT/$name"
  WORLD_HOME="$WORLD/home"
  WORLD_STATE="$WORLD_HOME/state"
  WORLD_DATA="$WORLD_HOME/data"
  WORLD_CONFIG="$WORLD_HOME/config"
  WORLD_PROJECT="$WORLD/project"
  WORLD_WT="$WORLD/worktree"
  WORLD_LOG="$WORLD/tmux.log"
  WORLD_LAUNCH="$WORLD/launch.log"
  mkdir -p "$WORLD_HOME" "$WORLD_STATE" "$WORLD_DATA/$id" "$WORLD_CONFIG"
  fm_git_worktree "$WORLD_PROJECT" "$WORLD_WT" "fm/$id"
  printf 'brief for %s\n' "$id" > "$WORLD_DATA/$id/brief.md"
  : > "$WORLD_LOG"
  : > "$WORLD_LAUNCH"
  WORLD_FAKEBIN=$(make_runtime_fakebin "$WORLD")
}

run_ship_spawn() {  # <id> [fm-spawn args...]
  local id=$1
  shift
  PATH="$WORLD_FAKEBIN:$BASE_PATH" TMUX='fake,1,0' FM_BACKEND=tmux \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD_HOME" \
    FM_STATE_OVERRIDE="$WORLD_STATE" FM_DATA_OVERRIDE="$WORLD_DATA" \
    FM_CONFIG_OVERRIDE="$WORLD_CONFIG" FM_PROJECTS_OVERRIDE="$WORLD_HOME/projects" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WORLD_WT" \
    FM_FAKE_TMUX_LOG="$WORLD_LOG" FM_FAKE_LAUNCH_LOG="$WORLD_LAUNCH" \
    "$SPAWN" "$id" "$WORLD_PROJECT" "$@"
}

assert_cursor_launch_argv() {  # <launch-file> <cwd> <id> <state> <brief> <role> [model]
  local launch_file=$1 cwd=$2 id=$3 state=$4 brief=$5 role=$6 model=${7:-}
  local gen
  gen=$(cat "$state/$id.busy-gen")
  LAUNCH_FILE="$launch_file" EXPECT_BRIDGE="$BRIDGE" EXPECT_CWD="$cwd" \
    EXPECT_ID="$id" EXPECT_STATE="$state" EXPECT_BRIEF="$brief" \
    EXPECT_GEN="$gen" EXPECT_ROLE="$role" EXPECT_MODEL="$model" \
    python3 <<'PY' || fail "Cursor bridge launch argv did not match the runtime contract"
import os
import re
import shlex

with open(os.environ["LAUNCH_FILE"], encoding="utf-8") as handle:
    lines = [line.rstrip("\n") for line in handle if line.rstrip("\n")]
assert len(lines) == 1, lines
actual = shlex.split(lines[0])
while actual and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", actual[0]):
    actual.pop(0)
expected = [
    "exec",
    os.environ["EXPECT_BRIDGE"],
    "--cwd", os.environ["EXPECT_CWD"],
    "--task-id", os.environ["EXPECT_ID"],
    "--state-dir", os.environ["EXPECT_STATE"],
    "--brief", os.environ["EXPECT_BRIEF"],
    "--busy-gen", os.environ["EXPECT_GEN"],
    "--role", os.environ["EXPECT_ROLE"],
]
if os.environ["EXPECT_MODEL"]:
    expected.extend(["--model", os.environ["EXPECT_MODEL"]])
assert actual == expected, {"actual": actual, "expected": expected, "launch": lines[0]}
PY
}

test_cursor_ship_and_scout_launch_contract() {
  local id model state_real
  id=cursor-crew-runtime
  model="cursor model's beta"
  setup_ship_world cursor-crew "$id"
  run_ship_spawn "$id" cursor --model "$model" >/dev/null \
    || fail "Cursor crew spawn failed"
  state_real=$(cd "$WORLD_STATE" && pwd -P)
  assert_cursor_launch_argv "$WORLD_LAUNCH" "$WORLD_WT" "$id" "$state_real" \
    "$WORLD_DATA/$id/brief.md" crew "$model"
  assert_grep 'harness=cursor' "$WORLD_STATE/$id.meta" \
    "Cursor crew metadata lost harness identity"
  assert_grep "model=$model" "$WORLD_STATE/$id.meta" \
    "Cursor crew metadata lost model"
  assert_grep 'effort=default' "$WORLD_STATE/$id.meta" \
    "Cursor crew metadata must record default effort"
  assert_grep 'busy_gen=' "$WORLD_STATE/$id.meta" \
    "Cursor crew metadata lost busy generation"
  assert_not_contains "$(cat "$WORLD_LAUNCH")" "agent --trust" \
    "fm-spawn must launch the bridge, not an interactive Cursor agent"
  cleanup_task_tmp "$id"

  id=cursor-scout-runtime
  setup_ship_world cursor-scout "$id"
  run_ship_spawn "$id" cursor --scout >/dev/null \
    || fail "Cursor scout spawn failed"
  state_real=$(cd "$WORLD_STATE" && pwd -P)
  assert_cursor_launch_argv "$WORLD_LAUNCH" "$WORLD_WT" "$id" "$state_real" \
    "$WORLD_DATA/$id/brief.md" scout
  assert_grep 'kind=scout' "$WORLD_STATE/$id.meta" \
    "Cursor scout metadata lost kind"
  assert_grep 'model=default' "$WORLD_STATE/$id.meta" \
    "Cursor scout default model metadata changed"
  cleanup_task_tmp "$id"
  pass "Cursor crew/scout launch only the absolute ACP bridge with exact role, model, paths, and busy generation"
}

setup_secondmate_world() {  # <name> <id>
  local name=$1 id=$2
  WORLD="$TMP_ROOT/$name"
  WORLD_HOME="$WORLD/primary-home"
  WORLD_STATE="$WORLD_HOME/state"
  WORLD_DATA="$WORLD_HOME/data"
  WORLD_CONFIG="$WORLD_HOME/config"
  WORLD_SM="$WORLD/secondmate-home"
  WORLD_LOG="$WORLD/tmux.log"
  WORLD_LAUNCH="$WORLD/launch.log"
  mkdir -p "$WORLD_STATE" "$WORLD_DATA" "$WORLD_CONFIG"
  mkdir -p "$WORLD_SM/bin" "$WORLD_SM/data" "$WORLD_SM/state" \
    "$WORLD_SM/config" "$WORLD_SM/projects"
  WORLD_SM=$(cd "$WORLD_SM" && pwd -P)
  printf '# Firstmate\n' > "$WORLD_SM/AGENTS.md"
  printf '%s\n' "$id" > "$WORLD_SM/.fm-secondmate-home"
  printf 'secondmate charter\n' > "$WORLD_SM/data/charter.md"
  : > "$WORLD_LOG"
  : > "$WORLD_LAUNCH"
  WORLD_FAKEBIN=$(make_runtime_fakebin "$WORLD")
}

run_secondmate_spawn() {  # <id> [fm-spawn args before --secondmate]
  local id=$1
  shift
  PATH="$WORLD_FAKEBIN:$BASE_PATH" TMUX='' FM_BACKEND=tmux \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD_HOME" \
    FM_STATE_OVERRIDE="$WORLD_STATE" FM_DATA_OVERRIDE="$WORLD_DATA" \
    FM_CONFIG_OVERRIDE="$WORLD_CONFIG" FM_PROJECTS_OVERRIDE="$WORLD_HOME/projects" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_TMUX_LOG="$WORLD_LOG" \
    FM_FAKE_LAUNCH_LOG="$WORLD_LAUNCH" \
    "$SPAWN" "$id" "$@" --secondmate
}

test_cursor_secondmate_launch_and_bare_adapter_resolution() {
  local id state_real
  id=cursor-secondmate-runtime
  setup_secondmate_world cursor-secondmate "$id"
  printf '%s\n' 'cursor cursor-secondmate-model' > "$WORLD_CONFIG/secondmate-harness"
  run_secondmate_spawn "$id" "$WORLD_SM" >/dev/null \
    || fail "configured Cursor secondmate spawn failed"
  state_real=$(cd "$WORLD_STATE" && pwd -P)
  assert_cursor_launch_argv "$WORLD_LAUNCH" "$WORLD_SM" "$id" "$state_real" \
    "$WORLD_SM/data/charter.md" secondmate cursor-secondmate-model
  assert_grep 'kind=secondmate' "$WORLD_STATE/$id.meta" \
    "Cursor secondmate metadata lost kind"
  assert_grep 'busy_gen=' "$WORLD_STATE/$id.meta" \
    "Cursor secondmate must arm and record the bridge's required busy generation"
  cleanup_task_tmp "$id"

  id=cursor-bare-secondmate
  setup_secondmate_world cursor-bare-secondmate "$id"
  fm_write_meta "$WORLD_STATE/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WORLD_SM" \
    "project=$WORLD_SM" \
    "harness=codex" \
    "kind=secondmate" \
    "home=$WORLD_SM"
  run_secondmate_spawn "$id" cursor >/dev/null \
    || fail "bare positional Cursor secondmate adapter did not reuse the recorded home"
  state_real=$(cd "$WORLD_STATE" && pwd -P)
  assert_cursor_launch_argv "$WORLD_LAUNCH" "$WORLD_SM" "$id" "$state_real" \
    "$WORLD_SM/data/charter.md" secondmate
  cleanup_task_tmp "$id"
  pass "Cursor secondmates use the bridge, arm busy state, and support the bare positional adapter on recovery"
}

test_cursor_effort_is_refused_before_endpoint_creation() {
  local id out rc
  id=cursor-effort-crew
  setup_ship_world cursor-effort-crew "$id"
  set +e
  out=$(run_ship_spawn "$id" cursor --effort high 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Cursor crew spawn accepted unsupported effort"
  assert_contains "$out" "Cursor harness does not support effort 'high'" \
    "Cursor crew effort refusal was not explicit"
  assert_not_contains "$(cat "$WORLD_LOG")" $'tmux\x1fnew-window' \
    "Cursor crew effort refusal happened after endpoint creation"
  cleanup_task_tmp "$id"

  id=cursor-effort-secondmate
  setup_secondmate_world cursor-effort-secondmate "$id"
  printf '%s\n' 'cursor cursor-model high' > "$WORLD_CONFIG/secondmate-harness"
  set +e
  out=$(run_secondmate_spawn "$id" "$WORLD_SM" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Cursor secondmate config accepted unsupported effort"
  assert_contains "$out" "Cursor harness does not support effort 'high'" \
    "Cursor secondmate configured effort refusal was not explicit"
  assert_not_contains "$(cat "$WORLD_LOG")" $'tmux\x1fnew-window' \
    "Cursor secondmate configured effort refusal happened after endpoint creation"
  cleanup_task_tmp "$id"
  pass "explicit and configured non-default Cursor effort fail clearly before endpoint creation"
}

test_raw_cursor_command_is_refused_before_endpoint_creation() {
  local id out rc
  id=cursor-raw-identity
  setup_ship_world cursor-raw-identity "$id"
  set +e
  out=$(run_ship_spawn "$id" "cursor --raw-adapter-flag" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    cleanup_task_tmp "$id"
    fail "raw command beginning with cursor inherited verified Cursor identity"
  fi
  assert_contains "$out" "raw launch command beginning with 'cursor' is refused" \
    "raw Cursor identity refusal was not explicit"
  assert_contains "$out" "use bare 'cursor' or --harness cursor" \
    "raw Cursor refusal did not name the verified adapter path"
  assert_not_contains "$(cat "$WORLD_LOG")" $'tmux\x1fnew-window' \
    "raw Cursor identity refusal happened after endpoint creation"
  assert_absent "$WORLD_STATE/$id.busy-gen" \
    "raw Cursor command armed trusted busy state"
  assert_absent "$WORLD_STATE/$id.meta" \
    "raw Cursor command wrote verified metadata"
  cleanup_task_tmp "$id"
  pass "raw commands cannot impersonate the verified Cursor ACP harness"
}

test_cursor_send_uses_line_protocol_and_ctrl_c_transport() {
  local home state fakebin log err got rc message
  home="$TMP_ROOT/send/home"
  state="$home/state"
  log="$TMP_ROOT/send/tmux.log"
  err="$TMP_ROOT/send/send.err"
  mkdir -p "$state"
  : > "$log"
  fakebin=$(make_runtime_fakebin "$TMP_ROOT/send")
  fm_write_meta "$state/cursor-send.meta" \
    "window=sess:fm-cursor-send" "harness=cursor" "kind=ship"

  message='C-c Enter Escape Tab'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_CURSOR_PROCESS_TREE=1 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    "$SEND" cursor-send "$message" >/dev/null 2>&1 \
    || fail "Cursor text send failed"
  got=$(cat "$log")
  assert_contains "$got" $'send-keys\x1f-t\x1fsess:fm-cursor-send\x1f-l\x1fC-c Enter Escape Tab' \
    "Cursor text containing tmux key names was not sent as literal bytes"
  assert_contains "$got" $'send-keys\x1f-t\x1fsess:fm-cursor-send\x1fEnter' \
    "Cursor literal line was not followed by one Enter"
  [ "$(printf '%s\n' "$got" | grep -c 'C-c Enter Escape Tab' || true)" -eq 1 ] \
    || fail "Cursor message text was typed more than once"
  assert_not_contains "$got" $'tmux\x1fcapture-pane' \
    "Cursor text send parsed terminal UI despite the ACP line protocol"

  : > "$log"
  set +e
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_PANE_COMMAND=zsh \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    "$SEND" cursor-send "git status" >/dev/null 2>"$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Cursor send accepted a dead bridge shell"
  assert_contains "$(cat "$err")" "verified Cursor ACP bridge is not alive" \
    "dead Cursor bridge refusal was not explicit"
  assert_not_contains "$(cat "$log")" $'\x1f-l\x1fgit status' \
    "Cursor prompt was typed into the shell after bridge exit"

  : > "$log"
  set +e
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_CURSOR_PROCESS_TREE=1 \
    FM_FAKE_PANE_COMMAND=claude FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    "$SEND" cursor-send "do not deliver to Claude" >/dev/null 2>"$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Cursor send accepted a different live harness"
  assert_contains "$(cat "$err")" "verified Cursor ACP bridge is not alive" \
    "wrong-harness Cursor refusal was not explicit"
  assert_not_contains "$(cat "$log")" $'\x1f-l\x1fdo not deliver to Claude' \
    "Cursor prompt was typed into another live harness"

  : > "$log"
  set +e
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_CURSOR_PROCESS_TREE=1 \
    FM_FAKE_TMUX_FAIL_LINE=1 FM_SEND_SETTLE=0 \
    "$SEND" cursor-send "must fail once" >/dev/null 2>"$err"
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "Cursor line transport failure must return delivery-unknown rc 3, got $rc"
  assert_contains "$(cat "$err")" "delivery unknown; do not resend" \
    "ordinary Cursor line failure did not forbid duplicate resend"
  got=$(cat "$log")
  [ "$(printf '%s\n' "$got" | grep -c 'must fail once' || true)" -eq 1 ] \
    || fail "Cursor line transport failure retried or retyped the message"
  assert_not_contains "$got" $'tmux\x1fcapture-pane' \
    "failed Cursor line transport fell back to composer parsing"

  fm_write_meta "$state/claude-send.meta" \
    "window=sess:fm-claude-send" "harness=claude" "kind=ship"
  : > "$log"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_CURSOR_PROCESS_TREE=1 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    "$SEND" claude-send "composer verified" >/dev/null 2>&1 \
    || fail "representative Claude text send regressed"
  got=$(cat "$log")
  assert_contains "$got" $'\x1f-l\x1fcomposer verified' \
    "Claude no longer uses the original literal composer submit path"
  assert_contains "$got" $'tmux\x1fcapture-pane' \
    "Claude no longer verifies composer submission"

  : > "$log"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_CURSOR_PROCESS_TREE=1 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    "$SEND" cursor-send --key C-c >/dev/null 2>&1 \
    || fail "Cursor C-c send failed"
  got=$(cat "$log")
  assert_contains "$got" $'send-keys\x1f-t\x1fsess:fm-cursor-send\x1fC-c' \
    "Cursor cancellation did not send C-c to the bridge"
  assert_not_contains "$got" $'\x1fEscape' \
    "Cursor cancellation must not be mapped to Escape"
  pass "Cursor uses one backend line send without TUI parsing; failures are single-shot and C-c remains unchanged"
}

test_cursor_secondmate_partial_send_preserves_pending_expectation() {
  local home state fakebin log err rc record corr marker got
  home="$TMP_ROOT/send-partial/home"
  state="$home/state"
  log="$TMP_ROOT/send-partial/tmux.log"
  err="$TMP_ROOT/send-partial/send.err"
  mkdir -p "$state"
  : >"$log"
  fakebin=$(make_runtime_fakebin "$TMP_ROOT/send-partial")
  fm_write_meta "$state/cursor-sm-send.meta" \
    "window=sess:fm-cursor-sm-send" "harness=cursor" "kind=secondmate" \
    "home=$TMP_ROOT/send-partial/secondmate-home"

  set +e
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_CURSOR_PROCESS_TREE=1 \
    FM_FAKE_TMUX_FAIL_ENTER=1 FM_SEND_SETTLE=0 \
    "$SEND" cursor-sm-send "partial C-c Enter" >/dev/null 2>"$err"
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "partial Cursor secondmate send must return delivery-unknown rc 3, got $rc"
  assert_contains "$(cat "$err")" "delivery unknown; do not resend" \
    "partial Cursor secondmate send did not forbid duplicate resend"
  got=$(cat "$log")
  assert_contains "$got" $'\x1f-l\x1f' \
    "partial Cursor secondmate send did not stage literal text before Enter failed"
  [ "$(printf '%s\n' "$got" | grep -c 'partial C-c Enter' || true)" -eq 1 ] \
    || fail "partial Cursor secondmate send retyped the message"
  assert_not_contains "$got" $'tmux\x1fcapture-pane' \
    "partial Cursor send fell back to composer parsing"

  record=
  for candidate in "$state/pending-replies"/*; do
    [ -f "$candidate" ] || continue
    record=$candidate
    break
  done
  [ -n "$record" ] || fail "partial Cursor send discarded its pending-reply record"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  corr=$(fm_pending_reply_get "$record" corr_id)
  marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
  assert_present "$marker" "partial Cursor send discarded its attempted delivery marker"
  assert_grep "attempted=" "$marker" \
    "partial Cursor send changed the delivery marker away from attempted"
  [ -z "$(fm_pending_reply_get "$record" delivered_epoch)" ] \
    || fail "partial Cursor send falsely confirmed delivery"
  pass "partial Cursor secondmate delivery remains recoverable and explicitly forbids resend"
}

test_cursor_rejects_multiline_before_backend_or_pending_state() {
  local home state fakebin log err rc
  home="$TMP_ROOT/send-multiline/home"
  state="$home/state"
  log="$TMP_ROOT/send-multiline/tmux.log"
  err="$TMP_ROOT/send-multiline/send.err"
  mkdir -p "$state"
  : >"$log"
  fakebin=$(make_runtime_fakebin "$TMP_ROOT/send-multiline")
  fm_write_meta "$state/cursor-multiline-ship.meta" \
    "window=sess:fm-cursor-multiline-ship" "harness=cursor" "kind=ship"
  fm_write_meta "$state/cursor-multiline-sm.meta" \
    "window=sess:fm-cursor-multiline-sm" "harness=cursor" "kind=secondmate" \
    "home=$TMP_ROOT/send-multiline/secondmate-home"

  set +e
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" cursor-multiline-ship $'first line\nsecond line' >/dev/null 2>"$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Cursor ship accepted LF-delimited input"
  assert_contains "$(cat "$err")" "Cursor input must be exactly one CR/LF-free line" \
    "Cursor ship multiline refusal was not explicit"
  [ ! -s "$log" ] || fail "Cursor ship multiline refusal called the backend"

  : >"$log"
  set +e
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" cursor-multiline-sm $'first line\rsecond line' >/dev/null 2>"$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Cursor secondmate accepted CR-delimited input"
  assert_contains "$(cat "$err")" "Cursor input must be exactly one CR/LF-free line" \
    "Cursor secondmate multiline refusal was not explicit"
  [ ! -s "$log" ] || fail "Cursor secondmate multiline refusal called the backend"
  assert_absent "$state/pending-replies" \
    "Cursor secondmate multiline refusal created pending-reply state"
  pass "Cursor CR/LF framing is rejected before backend delivery or pending state"
}

test_backend_line_dispatch_preserves_expected_labels() {
  local out
  out=$(bash -c '
    . "$1/bin/fm-backend.sh"
    fm_backend_source zellij
    fm_backend_zellij_send_text_line() { printf "zellij:%s:%s:%s\n" "$1" "$2" "$3"; }
    fm_backend_send_text_line zellij z-target z-text z-label
    fm_backend_source cmux
    fm_backend_cmux_send_text_line() { printf "cmux:%s:%s:%s\n" "$1" "$2" "$3"; }
    fm_backend_send_text_line cmux c-target c-text c-label
  ' _ "$ROOT")
  [ "$out" = $'zellij:z-target:z-text:z-label\ncmux:c-target:c-text:c-label' ] \
    || fail "backend line dispatch dropped zellij/cmux expected labels: $out"
  pass "backend-independent line dispatch preserves zellij/cmux expected-label arguments"
}

test_claude_and_codex_launch_contracts_remain_unchanged() {
  local id launch
  id=cursor-regression-claude
  setup_ship_world claude-regression "$id"
  run_ship_spawn "$id" claude >/dev/null \
    || fail "representative Claude spawn regressed"
  launch=$(cat "$WORLD_LAUNCH")
  assert_contains "$launch" \
    'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions' \
    "Claude launch prefix changed while wiring Cursor"
  assert_contains "$launch" 'fm-operational-input.sh' \
    "Claude launch lost operational input encoding"
  cleanup_task_tmp "$id"

  id=cursor-regression-codex
  setup_ship_world codex-regression "$id"
  run_ship_spawn "$id" codex >/dev/null \
    || fail "representative Codex spawn regressed"
  launch=$(cat "$WORLD_LAUNCH")
  assert_contains "$launch" 'codex --dangerously-bypass-approvals-and-sandbox -c' \
    "Codex launch prefix changed while wiring Cursor"
  assert_contains "$launch" 'notify=[' \
    "Codex launch lost its turn-end notification"
  cleanup_task_tmp "$id"
  pass "representative Claude and Codex spawn templates remain unchanged"
}

test_cursor_ship_and_scout_launch_contract
test_cursor_secondmate_launch_and_bare_adapter_resolution
test_cursor_effort_is_refused_before_endpoint_creation
test_raw_cursor_command_is_refused_before_endpoint_creation
test_cursor_send_uses_line_protocol_and_ctrl_c_transport
test_cursor_secondmate_partial_send_preserves_pending_expectation
test_cursor_rejects_multiline_before_backend_or_pending_state
test_backend_line_dispatch_preserves_expected_labels
test_claude_and_codex_launch_contracts_remain_unchanged

echo "all fm-cursor-runtime-wiring tests passed"
