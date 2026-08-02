#!/usr/bin/env bash
# Hermetic behavior tests for the Cursor ACP CrewMate control bridge.
# A focused fake ACP server owns every protocol peer interaction; no real
# Cursor agent, network request, model, or account is used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/bin/fm-cursor-acp-bridge.mjs"
FAKE_AGENT="$ROOT/tests/fixtures/cursor-acp/fake-agent.mjs"
OP_INPUT="$ROOT/bin/fm-operational-input.sh"
NODE_BIN=$(command -v node)
TMP_ROOT=$(fm_test_tmproot fm-cursor-acp-bridge)
ACTIVE_PIDS=

cleanup() {
  local pid
  for pid in $ACTIVE_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
  return 0
}
trap cleanup EXIT

assert_present "$FAKE_AGENT" "focused fake Cursor ACP server fixture is missing"
[ -x "$FAKE_AGENT" ] || fail "fake Cursor ACP server fixture must be executable"
assert_present "$BRIDGE" "bin/fm-cursor-acp-bridge.mjs is missing"

setup_case() { # <name>
  CASE_ROOT="$TMP_ROOT/$1"
  CASE_CWD="$CASE_ROOT/work"
  CASE_STATE="$CASE_ROOT/state"
  CASE_BRIEF="$CASE_ROOT/brief.md"
  CASE_LOG="$CASE_ROOT/acp.jsonl"
  CASE_BUSY_LOG="$CASE_ROOT/busy.log"
  CASE_OUT="$CASE_ROOT/stdout"
  CASE_ERR="$CASE_ROOT/stderr"
  mkdir -p "$CASE_CWD" "$CASE_STATE"
  printf 'Do the exact assigned work.\n' >"$CASE_BRIEF"
  : >"$CASE_BUSY_LOG"
}

make_busy_writer() { # <case-root>
  BUSY_WRITER="$1/fake-busy-event.sh"
  cat >"$BUSY_WRITER" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$FM_FAKE_BUSY_LOG"
if [ -n "${FM_FAKE_BUSY_FAIL_STATE:-}" ] && [ "${4:-}" = "$FM_FAKE_BUSY_FAIL_STATE" ]; then
  printf 'fake busy writer refused %s\n' "${4:-missing}" >&2
  exit 1
fi
block_state=${FM_FAKE_BUSY_BLOCK_STATE:-busy}
if [ -n "${FM_FAKE_BUSY_BLOCK_DIR:-}" ] && [ "${4:-}" = "$block_state" ]; then
  if [ "${FM_FAKE_BUSY_IGNORE_TERM:-0}" = 1 ]; then
    trap '' TERM
  fi
  [ -z "${FM_FAKE_BUSY_PID_FILE:-}" ] || printf '%s\n' "$$" >"$FM_FAKE_BUSY_PID_FILE"
  if [ -n "${FM_FAKE_BUSY_DESCENDANT_PID_FILE:-}" ]; then
    (
      trap '' TERM
      while :; do sleep 1; done
    ) &
    printf '%s\n' "$!" >"$FM_FAKE_BUSY_DESCENDANT_PID_FILE"
  fi
  : >"$FM_FAKE_BUSY_BLOCK_DIR/entered"
  while [ ! -e "$FM_FAKE_BUSY_BLOCK_DIR/release" ]; do
    sleep 0.02
  done
fi
SH
  chmod +x "$BUSY_WRITER"
}

run_bridge() { # <scenario> [bridge args...], stdin inherited
  local scenario=$1
  shift
  make_busy_writer "$CASE_ROOT"
  env \
    FM_FAKE_ACP_SCENARIO="$scenario" \
    FM_FAKE_ACP_LOG="$CASE_LOG" \
    FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" \
    FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    node "$BRIDGE" \
      --cwd "$CASE_CWD" \
      --task-id task-3 \
      --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" \
      --busy-gen gen-3 \
      --agent-bin "$FAKE_AGENT" \
      "$@"
}

json_log_assert() { # <log> <JavaScript assertion body>
  node --input-type=module - "$1" "$2" <<'JS'
import fs from "node:fs";
const [path, body] = process.argv.slice(2);
const rows = fs.readFileSync(path, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};
new Function("rows", "assert", body)(rows, assert);
JS
}

file_mode() {
  stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null
}

expect_preflight_failure() { # <label> <args...>
  local label=$1 rc
  shift
  rm -f "$CASE_LOG"
  set +e
  env FM_FAKE_ACP_LOG="$CASE_LOG" FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    node "$BRIDGE" "$@" </dev/null >"$CASE_OUT" 2>"$CASE_ERR"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$label must fail before child startup"
  [ ! -s "$CASE_LOG" ] || fail "$label started the ACP child before validation"
  [ -s "$CASE_ERR" ] || fail "$label did not print an actionable diagnostic"
}

wait_bounded_exit() { # <pid> <max 20ms ticks>
  local pid=$1 max_ticks=$2 ticks=0
  while [ "$ticks" -lt "$max_ticks" ] && kill -0 "$pid" 2>/dev/null; do
    ticks=$((ticks + 1))
    sleep 0.02
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 124
  fi
  set +e
  wait "$pid"
  BOUNDED_RC=$?
  set -e
  return 0
}

assert_single_fatal_publication() {
  [ "$(grep -c -- '--event process-exit$' "$CASE_BUSY_LOG" 2>/dev/null || true)" -eq 1 ] \
    || fail "$1 must publish unknown/process-exit exactly once"
  [ "$(grep -c '^failed: ' "$CASE_STATE/task-3.status" 2>/dev/null || true)" -eq 1 ] \
    || fail "$1 must append failed status exactly once"
}

test_repeated_termination_signals_do_not_extend_first_deadline() {
  setup_case repeated-termination-deadline
  make_busy_writer "$CASE_ROOT"
  NODE_BIN="$NODE_BIN" BRIDGE="$BRIDGE" FAKE_AGENT="$FAKE_AGENT" \
    CASE_CWD="$CASE_CWD" CASE_STATE="$CASE_STATE" CASE_BRIEF="$CASE_BRIEF" \
    CASE_LOG="$CASE_LOG" CASE_BUSY_LOG="$CASE_BUSY_LOG" BUSY_WRITER="$BUSY_WRITER" \
    CASE_OUT="$CASE_OUT" CASE_ERR="$CASE_ERR" python3 <<'PY' \
    || fail "repeated TERM/HUP extended the first shutdown deadline: $(cat "$CASE_ERR")"
import json
import os
import signal
import subprocess
import time

env = os.environ.copy()
env.update({
    "FM_FAKE_ACP_SCENARIO": "signal-cancel-no-response",
    "FM_FAKE_ACP_LOG": env["CASE_LOG"],
    "FM_FAKE_BUSY_LOG": env["CASE_BUSY_LOG"],
    "FM_CURSOR_BUSY_EVENT": env["BUSY_WRITER"],
})
argv = [
    env["NODE_BIN"], env["BRIDGE"],
    "--cwd", env["CASE_CWD"],
    "--task-id", "task-3",
    "--state-dir", env["CASE_STATE"],
    "--brief", env["CASE_BRIEF"],
    "--busy-gen", "gen-3",
    "--agent-bin", env["FAKE_AGENT"],
]

def rows():
    try:
        with open(env["CASE_LOG"], encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]
    except FileNotFoundError:
        return []

def wait_for(predicate, process, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        if process.poll() is not None:
            return False
        time.sleep(0.02)
    return False

def cleanup_agent_group():
    spawn_row = next((row for row in rows() if row.get("type") == "spawn"), None)
    if spawn_row:
        try:
            os.killpg(int(spawn_row["pid"]), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

with open(env["CASE_OUT"], "wb") as stdout, open(env["CASE_ERR"], "wb") as stderr:
    process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr, env=env)
    try:
        process.stdin.write(b"cancel then signal storm\n")
        process.stdin.flush()
        if not wait_for(
            lambda: any(row.get("type") == "signal-ready" for row in rows()),
            process,
        ):
            raise RuntimeError("busy prompt never became cancellable")
        process.send_signal(signal.SIGINT)
        if not wait_for(
            lambda: any(
                row.get("type") == "client-notification"
                and row.get("method") == "session/cancel"
                for row in rows()
            ),
            process,
        ):
            raise RuntimeError("SIGINT cancellation notification was not observed")
        first_termination = time.monotonic()
        process.send_signal(signal.SIGTERM)
        sent = 1
        while process.poll() is None and time.monotonic() - first_termination < 2.6:
            time.sleep(0.05)
            try:
                process.send_signal(signal.SIGHUP if sent % 2 else signal.SIGTERM)
                sent += 1
            except ProcessLookupError:
                break
        remaining = max(0.01, first_termination + 3.5 - time.monotonic())
        try:
            code = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("shutdown remained alive beyond the first termination deadline") from error
        elapsed = time.monotonic() - first_termination
        if code != 0:
            raise RuntimeError(f"signal storm exited {code}, expected clean exit 0")
        if elapsed > 3.5:
            raise RuntimeError(f"signal storm exit took {elapsed:.3f}s from first termination")
        if sent < 10:
            raise RuntimeError(f"signal storm sent only {sent} repeated signals")
    except Exception:
        if process.poll() is None:
            process.kill()
            process.wait()
        cleanup_agent_group()
        raise
status = os.path.join(env["CASE_STATE"], "task-3.status")
if os.path.exists(status):
    with open(status, encoding="utf-8") as handle:
        if any(line.startswith("failed:") for line in handle):
            raise RuntimeError("intentional repeated termination wrote failed status")
PY
  assert_no_grep "--event protocol-error" "$CASE_BUSY_LOG" \
    "repeated termination published a false protocol error"
  pass "repeated alternating TERM/HUP signals preserve the first shutdown deadline"
}

test_detached_acp_process_group_is_fully_reaped() {
  local mode
  for mode in exit term fatal; do
    setup_case "pipe-grandchild-$mode"
    make_busy_writer "$CASE_ROOT"
    MODE="$mode" NODE_BIN="$NODE_BIN" BRIDGE="$BRIDGE" FAKE_AGENT="$FAKE_AGENT" \
      CASE_CWD="$CASE_CWD" CASE_STATE="$CASE_STATE" CASE_BRIEF="$CASE_BRIEF" \
      CASE_LOG="$CASE_LOG" CASE_BUSY_LOG="$CASE_BUSY_LOG" BUSY_WRITER="$BUSY_WRITER" \
      CASE_OUT="$CASE_OUT" CASE_ERR="$CASE_ERR" python3 <<'PY' \
      || fail "$mode shutdown did not fully reap the detached ACP process group: $(cat "$CASE_ERR")"
import json
import os
import signal
import subprocess
import time

env = os.environ.copy()
env.update({
    "FM_FAKE_ACP_SCENARIO": (
        "pipe-grandchild-fatal" if env["MODE"] == "fatal" else "pipe-grandchild"
    ),
    "FM_FAKE_ACP_LOG": env["CASE_LOG"],
    "FM_FAKE_BUSY_LOG": env["CASE_BUSY_LOG"],
    "FM_CURSOR_BUSY_EVENT": env["BUSY_WRITER"],
})
argv = [
    env["NODE_BIN"], env["BRIDGE"],
    "--cwd", env["CASE_CWD"],
    "--task-id", "task-3",
    "--state-dir", env["CASE_STATE"],
    "--brief", env["CASE_BRIEF"],
    "--busy-gen", "gen-3",
    "--agent-bin", env["FAKE_AGENT"],
]

def rows():
    try:
        with open(env["CASE_LOG"], encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]
    except FileNotFoundError:
        return []

def live(pid):
    try:
        stat = subprocess.check_output(
            ["ps", "-o", "stat=", "-p", str(pid)],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return bool(stat) and not stat.startswith("Z")
    except (OSError, subprocess.CalledProcessError):
        return False

def cleanup_group():
    spawn_row = next((row for row in rows() if row.get("type") == "spawn"), None)
    if spawn_row:
        try:
            os.killpg(int(spawn_row["pid"]), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

with open(env["CASE_OUT"], "wb") as stdout, open(env["CASE_ERR"], "wb") as stderr:
    process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr, env=env)
    try:
        deadline = time.monotonic() + 5
        grandchild = None
        while time.monotonic() < deadline:
            grandchild_row = next(
                (row for row in rows() if row.get("type") == "pipe-grandchild"),
                None,
            )
            if grandchild_row:
                grandchild = int(grandchild_row["pid"])
                if env["MODE"] == "fatal" or os.path.exists(
                    os.path.join(env["CASE_STATE"], "task-3.cursor-session.json")
                ):
                    break
            if process.poll() is not None and not grandchild_row:
                break
            time.sleep(0.02)
        if grandchild is None:
            raise RuntimeError("fake ACP grandchild was never observed")
        if env["MODE"] == "exit":
            process.stdin.write(b"/exit\n")
            process.stdin.flush()
        elif env["MODE"] == "term":
            process.send_signal(signal.SIGTERM)
        expected = 1 if env["MODE"] == "fatal" else 0
        try:
            code = process.wait(timeout=6)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("bridge retained inherited ACP pipes after direct child exit") from error
        if code != expected:
            raise RuntimeError(f"bridge exited {code}, expected {expected}")
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and live(grandchild):
            time.sleep(0.02)
        if live(grandchild):
            raise RuntimeError(f"ACP grandchild {grandchild} survived bridge shutdown")
    except Exception:
        if process.poll() is None:
            process.kill()
            process.wait()
        cleanup_group()
        raise
PY
  done
  pass "/exit, SIGTERM, and fatal shutdown fully reap detached ACP groups with inherited pipes"
}

test_status_append_rejects_post_preflight_fifo_and_symlink() {
  local replacement
  for replacement in fifo symlink; do
    setup_case "status-toctou-$replacement"
    make_busy_writer "$CASE_ROOT"
    REPLACEMENT="$replacement" NODE_BIN="$NODE_BIN" BRIDGE="$BRIDGE" FAKE_AGENT="$FAKE_AGENT" \
      CASE_CWD="$CASE_CWD" CASE_STATE="$CASE_STATE" CASE_BRIEF="$CASE_BRIEF" \
      CASE_LOG="$CASE_LOG" CASE_BUSY_LOG="$CASE_BUSY_LOG" BUSY_WRITER="$BUSY_WRITER" \
      CASE_OUT="$CASE_OUT" CASE_ERR="$CASE_ERR" python3 <<'PY' \
      || fail "post-preflight status $replacement was not rejected safely: $(cat "$CASE_ERR")"
import json
import os
import signal
import subprocess
import time

env = os.environ.copy()
control = os.path.join(env["CASE_STATE"], "release-permission")
status = os.path.join(env["CASE_STATE"], "task-3.status")
outside = os.path.join(env["CASE_STATE"], "outside-status")
env.update({
    "FM_FAKE_ACP_SCENARIO": "permission-cancel-race",
    "FM_FAKE_ACP_LOG": env["CASE_LOG"],
    "FM_FAKE_ACP_RACE_CONTROL": control,
    "FM_FAKE_BUSY_LOG": env["CASE_BUSY_LOG"],
    "FM_CURSOR_BUSY_EVENT": env["BUSY_WRITER"],
})
argv = [
    env["NODE_BIN"], env["BRIDGE"],
    "--cwd", env["CASE_CWD"],
    "--task-id", "task-3",
    "--state-dir", env["CASE_STATE"],
    "--brief", env["CASE_BRIEF"],
    "--busy-gen", "gen-3",
    "--agent-bin", env["FAKE_AGENT"],
]

def rows():
    try:
        with open(env["CASE_LOG"], encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]
    except FileNotFoundError:
        return []

def cleanup_agent_group():
    spawn_row = next((row for row in rows() if row.get("type") == "spawn"), None)
    if spawn_row:
        try:
            os.killpg(int(spawn_row["pid"]), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

with open(env["CASE_OUT"], "wb") as stdout, open(env["CASE_ERR"], "wb") as stderr:
    process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr, env=env)
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if any(row.get("type") == "permission-race-ready" for row in rows()):
                break
            if process.poll() is not None:
                raise RuntimeError("bridge exited before status replacement")
            time.sleep(0.02)
        else:
            raise RuntimeError("bridge never reached post-preflight permission point")
        if env["REPLACEMENT"] == "fifo":
            os.mkfifo(status)
        else:
            open(outside, "wb").close()
            os.symlink(outside, status)
        open(control, "wb").close()
        try:
            code = process.wait(timeout=5)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("status append blocked on a post-preflight FIFO") from error
        if code != 1:
            raise RuntimeError(f"unsafe status replacement exited {code}, expected fatal exit 1")
        if os.path.exists(outside) and os.path.getsize(outside) != 0:
            raise RuntimeError("status symlink received an outside write")
    except Exception:
        if process.poll() is None:
            process.kill()
            process.wait()
        cleanup_agent_group()
        raise
PY
  done
  pass "every status append rejects post-preflight FIFO and symlink replacements without blocking"
}

test_spawn_error_and_close_only_are_bounded() {
  local bad_agent pid label
  for label in explicit default; do
    setup_case "spawn-$label"
    make_busy_writer "$CASE_ROOT"
    mkdir -p "$CASE_ROOT/fakebin"
    bad_agent="$CASE_ROOT/fakebin/agent"
    printf '#!/definitely/missing/interpreter\n' >"$bad_agent"
    chmod +x "$bad_agent"
    if [ "$label" = explicit ]; then
      env FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
        node "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
          --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$bad_agent" \
          </dev/null >"$CASE_OUT" 2>"$CASE_ERR" &
    else
      ln -s "$(command -v bash)" "$CASE_ROOT/fakebin/bash"
      ln -s "$(command -v cat)" "$CASE_ROOT/fakebin/cat"
      env PATH="$CASE_ROOT/fakebin" FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" \
        FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
        "$NODE_BIN" "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
          --brief "$CASE_BRIEF" --busy-gen gen-3 \
          </dev/null >"$CASE_OUT" 2>"$CASE_ERR" &
    fi
    pid=$!
    wait_bounded_exit "$pid" 200 \
      || fail "$label spawn error exceeded the bounded lifecycle timeout"
    [ "$BOUNDED_RC" -eq 1 ] \
      || fail "$label spawn error must exit 1, got $BOUNDED_RC"
    assert_grep "could not start ACP child" "$CASE_ERR" "$label spawn error diagnostic changed"
    assert_single_fatal_publication "$label spawn error"
  done

  setup_case child-close-only
  make_busy_writer "$CASE_ROOT"
  env FM_FAKE_ACP_SCENARIO=child-close-only FM_FAKE_ACP_LOG="$CASE_LOG" \
    FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    node "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      </dev/null >"$CASE_OUT" 2>"$CASE_ERR" &
  pid=$!
  wait_bounded_exit "$pid" 200 \
    || fail "close-only child exceeded the bounded TERM/KILL lifecycle timeout"
  [ "$BOUNDED_RC" -eq 1 ] || fail "close-only child must exit 1, got $BOUNDED_RC"
  [ "$(grep -c '^failed: ' "$CASE_STATE/task-3.status" 2>/dev/null || true)" -eq 1 ] \
    || fail "close-only fatal path appended duplicate failures"
  pass "spawn error/error-close and close-only TERM/KILL paths settle once within a fixed bound"
}

test_cli_preflight_rejects_invalid_input_before_spawn() {
  setup_case preflight
  make_busy_writer "$CASE_ROOT"
  local -a valid=(
    --cwd "$CASE_CWD"
    --task-id task-3
    --state-dir "$CASE_STATE"
    --brief "$CASE_BRIEF"
    --busy-gen gen-3
    --agent-bin "$FAKE_AGENT"
  )

  expect_preflight_failure "missing required arguments"
  expect_preflight_failure "unknown option" "${valid[@]}" --unknown value
  expect_preflight_failure "missing option value" "${valid[@]}" --model
  expect_preflight_failure "relative cwd" \
    --cwd relative --task-id task-3 --state-dir "$CASE_STATE" --brief "$CASE_BRIEF" \
    --busy-gen gen-3 --agent-bin "$FAKE_AGENT"
  expect_preflight_failure "relative state dir" \
    --cwd "$CASE_CWD" --task-id task-3 --state-dir relative --brief "$CASE_BRIEF" \
    --busy-gen gen-3 --agent-bin "$FAKE_AGENT"
  expect_preflight_failure "relative brief" \
    --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" --brief relative \
    --busy-gen gen-3 --agent-bin "$FAKE_AGENT"
  expect_preflight_failure "relative explicit agent binary" \
    --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" --brief "$CASE_BRIEF" \
    --busy-gen gen-3 --agent-bin relative-agent
  expect_preflight_failure "unsafe task id" \
    --cwd "$CASE_CWD" --task-id ../task --state-dir "$CASE_STATE" --brief "$CASE_BRIEF" \
    --busy-gen gen-3 --agent-bin "$FAKE_AGENT"
  expect_preflight_failure "unsafe busy gen" \
    --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" --brief "$CASE_BRIEF" \
    --busy-gen gen/3 --agent-bin "$FAKE_AGENT"
  expect_preflight_failure "invalid role" "${valid[@]}" --role captain
  expect_preflight_failure "missing state directory" \
    --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_ROOT/missing-state" \
    --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT"
  expect_preflight_failure "missing brief" \
    --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
    --brief "$CASE_ROOT/missing-brief" --busy-gen gen-3 --agent-bin "$FAKE_AGENT"
  pass "Cursor ACP bridge validates every startup boundary before spawning the child"
}

test_preflight_dependencies_and_failures_stop_before_agent() {
  local rc bad_busy sidecar outside

  setup_case preflight-relative-busy
  make_busy_writer "$CASE_ROOT"
  set +e
  FM_FAKE_ACP_LOG="$CASE_LOG" FM_CURSOR_BUSY_EVENT=relative-busy \
    "$NODE_BIN" "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      </dev/null >"$CASE_OUT" 2>"$CASE_ERR"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "relative busy writer must exit 1"
  [ ! -s "$CASE_LOG" ] || fail "relative busy writer started the agent"
  assert_grep "absolute" "$CASE_ERR" "relative busy writer diagnostic must require absolute path"

  setup_case preflight-nonexec-busy
  bad_busy="$CASE_ROOT/nonexec-busy"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$bad_busy"
  chmod 600 "$bad_busy"
  set +e
  FM_FAKE_ACP_LOG="$CASE_LOG" FM_CURSOR_BUSY_EVENT="$bad_busy" \
    "$NODE_BIN" "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      </dev/null >"$CASE_OUT" 2>"$CASE_ERR"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "non-executable busy writer must exit 1"
  [ ! -s "$CASE_LOG" ] || fail "non-executable busy writer started the agent"
  assert_grep "executable" "$CASE_ERR" "non-executable busy writer diagnostic changed"

  setup_case preflight-encode
  make_busy_writer "$CASE_ROOT"
  mkdir -p "$CASE_ROOT/fakebin"
  ln -s "$(command -v bash)" "$CASE_ROOT/fakebin/bash"
  cat >"$CASE_ROOT/fakebin/cat" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$CASE_ROOT/fakebin/cat"
  set +e
  PATH="$CASE_ROOT/fakebin" FM_FAKE_ACP_LOG="$CASE_LOG" \
    FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    "$NODE_BIN" "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      </dev/null >"$CASE_OUT" 2>"$CASE_ERR"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "launch-brief encode failure must exit 1"
  [ ! -s "$CASE_LOG" ] || fail "launch-brief encode failure started the agent"
  assert_grep "--event preflight-error" "$CASE_BUSY_LOG" "encode failure did not publish unknown/preflight-error"
  assert_safe_status_file "$CASE_STATE/task-3.status" 1

  setup_case preflight-sidecar-symlink
  make_busy_writer "$CASE_ROOT"
  outside="$CASE_ROOT/outside-sidecar"
  printf '{"version":1,"sessionId":"saved","cwd":"%s","role":"crew","updatedAt":"2026-08-02T00:00:00.000Z"}\n' \
    "$CASE_CWD" >"$outside"
  sidecar="$CASE_STATE/task-3.cursor-session.json"
  ln -s "$outside" "$sidecar"
  set +e
  FM_FAKE_ACP_LOG="$CASE_LOG" FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" \
    FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    "$NODE_BIN" "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      </dev/null >"$CASE_OUT" 2>"$CASE_ERR"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "sidecar symlink must exit 1"
  [ ! -s "$CASE_LOG" ] || fail "sidecar symlink started the agent"
  assert_grep "--event preflight-error" "$CASE_BUSY_LOG" "sidecar symlink did not publish preflight unknown"

  setup_case preflight-status-symlink
  make_busy_writer "$CASE_ROOT"
  outside="$CASE_ROOT/outside-status"
  : >"$outside"
  ln -s "$outside" "$CASE_STATE/task-3.status"
  set +e
  FM_FAKE_ACP_LOG="$CASE_LOG" FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" \
    FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    "$NODE_BIN" "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      </dev/null >"$CASE_OUT" 2>"$CASE_ERR"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "status symlink must exit 1"
  [ ! -s "$CASE_LOG" ] || fail "status symlink started the agent"
  [ ! -s "$outside" ] || fail "status symlink allowed an outside write"
  pass "preflight validates busy/encode/state targets and reports safe pre-spawn failures"
}

test_preflight_checks_state_write_and_brief_read_access() {
  local rc
  setup_case preflight-state-access
  make_busy_writer "$CASE_ROOT"
  chmod 500 "$CASE_STATE"
  set +e
  FM_FAKE_ACP_LOG="$CASE_LOG" FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" \
    FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    "$NODE_BIN" "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      </dev/null >"$CASE_OUT" 2>"$CASE_ERR"
  rc=$?
  set -e
  chmod 700 "$CASE_STATE"
  [ "$rc" -eq 1 ] || fail "non-writable state directory must exit 1"
  [ ! -s "$CASE_LOG" ] || fail "non-writable state directory started the agent"
  assert_grep "state directory" "$CASE_ERR" "state write diagnostic changed"

  setup_case preflight-brief-access
  make_busy_writer "$CASE_ROOT"
  chmod 000 "$CASE_BRIEF"
  set +e
  FM_FAKE_ACP_LOG="$CASE_LOG" FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" \
    FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    "$NODE_BIN" "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      </dev/null >"$CASE_OUT" 2>"$CASE_ERR"
  rc=$?
  set -e
  chmod 600 "$CASE_BRIEF"
  [ "$rc" -eq 1 ] || fail "unreadable brief must exit 1"
  [ ! -s "$CASE_LOG" ] || fail "unreadable brief started the agent"
  assert_grep "--event preflight-error" "$CASE_BUSY_LOG" "unreadable brief did not publish preflight unknown"
  assert_safe_status_file "$CASE_STATE/task-3.status" 1
  pass "preflight requires a writable state directory and readable brief"
}

test_sidecar_session_id_is_bounded_and_control_free() {
  local kind session_value rc
  for kind in control overlong; do
    setup_case "sidecar-id-$kind"
    if [ "$kind" = control ]; then
      session_value=$'saved\ndone: forged'
    else
      session_value=$(printf '%0600d' 0 | tr 0 X)
    fi
    SIDECAR="$CASE_STATE/task-3.cursor-session.json" SESSION_VALUE="$session_value" \
      CWD_VALUE="$CASE_CWD" \
      node --input-type=module <<'JS'
import fs from "node:fs";
fs.writeFileSync(process.env.SIDECAR, JSON.stringify({
  version: 1,
  sessionId: process.env.SESSION_VALUE,
  cwd: process.env.CWD_VALUE,
  role: "crew",
  updatedAt: "2026-08-02T00:00:00.000Z",
}) + "\n", { mode: 0o600 });
JS
    set +e
    printf '/exit\n' | run_bridge load-ok >"$CASE_OUT" 2>"$CASE_ERR"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$kind sidecar sessionId must exit 1"
    [ ! -s "$CASE_LOG" ] || fail "$kind sidecar sessionId started the agent"
    assert_grep "--event preflight-error" "$CASE_BUSY_LOG" "$kind sessionId did not publish preflight unknown"
    assert_safe_status_file "$CASE_STATE/task-3.status" 1
  done
  pass "sidecar sessionId rejects controls and values beyond the fixed bound"
}

test_new_session_protocol_rendering_and_atomic_state() {
  setup_case new-session
  set +e
  printf '/exit\n' | run_bridge happy --model cursor-model --role scout >"$CASE_OUT" 2>"$CASE_ERR"
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "new-session bridge run failed: $(cat "$CASE_ERR")"

  local expected_prompt sidecar
  expected_prompt=$(printf 'Read the brief at %s and follow it exactly.' "$CASE_BRIEF" \
    | "$OP_INPUT" encode launch-brief)
  sidecar="$CASE_STATE/task-3.cursor-session.json"

  EXPECT_CWD="$CASE_CWD"
  EXPECT_CWD_REAL=$(cd "$CASE_CWD" && pwd -P)
  EXPECT_PROMPT="$expected_prompt"
  export EXPECT_CWD EXPECT_CWD_REAL EXPECT_PROMPT
  json_log_assert "$CASE_LOG" '
      const spawn = rows.find((row) => row.type === "spawn");
      assert(spawn, "missing child spawn record");
      assert(JSON.stringify(spawn.argv) === JSON.stringify(["--trust", "--force", "--model", "cursor-model", "acp"]), "root flags/model/acp argv order changed");
      assert(spawn.cwd === process.env.EXPECT_CWD_REAL, "child cwd changed");
      const requests = rows.filter((row) => row.type === "client-request");
      assert(JSON.stringify(requests.slice(0, 4).map((row) => row.method)) === JSON.stringify(["initialize", "authenticate", "session/new", "session/prompt"]), "initialize/auth/new/prompt order changed");
      const init = requests[0].params;
      assert(init.protocolVersion === 1, "protocolVersion must be 1");
      assert(init.clientCapabilities.fs.readTextFile === false, "fs read capability must be false");
      assert(init.clientCapabilities.fs.writeTextFile === false, "fs write capability must be false");
      assert(init.clientCapabilities.terminal === false, "terminal capability must be false");
      assert(init.clientInfo.name === "firstmate-cursor-bridge" && init.clientInfo.version === "1", "clientInfo changed");
      assert(requests[1].params.methodId === "cursor_login", "authenticate method changed");
      assert(requests[2].params.cwd === process.env.EXPECT_CWD, "session/new cwd changed");
      assert(Array.isArray(requests[2].params.mcpServers) && requests[2].params.mcpServers.length === 0, "session/new must disable extra MCP servers");
      const prompt = requests[3].params.prompt;
      assert(prompt.length === 1 && prompt[0].type === "text", "prompt content shape changed");
      assert(prompt[0].text === process.env.EXPECT_PROMPT, "launch brief pointer was not typed exactly");
      assert(!JSON.stringify(rows).includes("Do the exact assigned work"), "brief contents leaked into ACP or argv");
  '

  assert_grep "hello from fake 1" "$CASE_OUT" "agent message chunk was not rendered"
  assert_grep "[update:tool_call]" "$CASE_OUT" "non-message session update lacks stable label"
  python3 - "$CASE_OUT" <<'PY' || fail "non-message update marker was joined to agent text"
import sys

output = open(sys.argv[1], encoding="utf-8").read()
if "hello from fake 1\n[update:tool_call]\n" not in output:
    raise SystemExit(1)
PY
  assert_no_grep '"jsonrpc"' "$CASE_OUT" "raw ACP JSON leaked to user stdout"
  assert_grep "[cursor-acp stderr] fake diagnostic" "$CASE_ERR" "child stderr prefix is missing"
  assert_grep "apply $CASE_STATE task-3 busy --gen gen-3 --source cursor-acp --event prompt-start" \
    "$CASE_BUSY_LOG" "prompt start did not publish busy"
  assert_grep "apply $CASE_STATE task-3 idle --gen gen-3 --source cursor-acp --event prompt-stop" \
    "$CASE_BUSY_LOG" "prompt completion did not publish idle"
  assert_present "$CASE_STATE/task-3.turn-ended" "prompt completion did not atomically publish turn end"
  assert_present "$sidecar" "new session did not persist a sidecar"
  [ "$(file_mode "$sidecar")" = 600 ] || fail "sidecar mode must be 0600, got $(file_mode "$sidecar")"
  if compgen -G "$sidecar.tmp.*" >/dev/null; then
    fail "atomic sidecar write left a temporary file"
  fi
  EXPECT_CWD="$CASE_CWD" SIDECAR="$sidecar" node --input-type=module <<'JS'
import fs from "node:fs";
const doc = JSON.parse(fs.readFileSync(process.env.SIDECAR, "utf8"));
if (
  doc.version !== 1
  || doc.sessionId !== "session-new-123"
  || doc.cwd !== process.env.EXPECT_CWD
  || doc.role !== "scout"
  || typeof doc.updatedAt !== "string"
  || Number.isNaN(Date.parse(doc.updatedAt))
) {
  throw new Error(`invalid sidecar: ${JSON.stringify(doc)}`);
}
JS
  pass "Cursor ACP new session preserves argv, typed pointer, rendering, busy lifecycle, and private atomic sidecar"
}

wait_for_prompt_count() { # <log> <count>
  local log=$1 want=$2 tries=0 got=0
  while [ "$tries" -lt 200 ]; do
    if [ -f "$log" ]; then
      got=$(grep -c '"type":"prompt"' "$log" 2>/dev/null || true)
      [ "$got" -ge "$want" ] && return 0
    fi
    tries=$((tries + 1))
    sleep 0.02
  done
  return 1
}

test_busy_input_is_fifo_queued() {
  setup_case fifo
  make_busy_writer "$CASE_ROOT"
  local fifo="$CASE_ROOT/stdin.fifo" pid rc
  mkfifo "$fifo"
  env FM_FAKE_ACP_SCENARIO=happy FM_FAKE_ACP_PROMPT_DELAY_MS=25 \
    FM_FAKE_ACP_LOG="$CASE_LOG" FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" \
    FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    node "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      <"$fifo" >"$CASE_OUT" 2>"$CASE_ERR" &
  pid=$!
  ACTIVE_PIDS="$ACTIVE_PIDS $pid"
  exec 9>"$fifo"
  printf 'C-c Enter\nsecond steer\n' >&9
  wait_for_prompt_count "$CASE_LOG" 3 \
    || fail "queued steer prompts did not drain"
  printf '/exit\n' >&9
  exec 9>&-
  set +e
  wait "$pid"
  rc=$?
  set -e
  ACTIVE_PIDS=${ACTIVE_PIDS// $pid/}
  [ "$rc" -eq 0 ] || fail "FIFO steer bridge run failed: $(cat "$CASE_ERR")"

  json_log_assert "$CASE_LOG" '
    const prompts = rows.filter((row) => row.type === "prompt");
    assert(prompts.length === 3, `expected exactly 3 prompts, got ${prompts.length}`);
    assert(prompts[1].params.prompt[0].text === "C-c Enter", "literal key-name steer changed before ACP prompt");
    assert(prompts[2].params.prompt[0].text === "second steer", "second queued steer lost FIFO order");
  '
  [ "$(grep -c ' prompt-start$' "$CASE_BUSY_LOG")" -eq 3 ] \
    || fail "each FIFO prompt must publish one busy event"
  [ "$(grep -c ' prompt-stop$' "$CASE_BUSY_LOG")" -eq 3 ] \
    || fail "each FIFO prompt must publish one idle event"
  pass "Cursor ACP bridge queues busy stdin in FIFO order and starts the next prompt only after completion"
}

write_sidecar() { # <cwd> <role>
  local cwd=$1 role=$2 sidecar="$CASE_STATE/task-3.cursor-session.json"
  printf '{"version":1,"sessionId":"saved-session","cwd":"%s","role":"%s","updatedAt":"2026-08-02T00:00:00.000Z"}\n' \
    "$cwd" "$role" >"$sidecar"
  chmod 600 "$sidecar"
}

test_load_resume_and_mismatch_refusal() {
  setup_case load-ok
  write_sidecar "$CASE_CWD" crew
  set +e
  printf '/exit\n' | run_bridge load-ok >"$CASE_OUT" 2>"$CASE_ERR"
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "valid session/load failed: $(cat "$CASE_ERR")"
  EXPECT_CWD="$CASE_CWD"
  export EXPECT_CWD
  json_log_assert "$CASE_LOG" '
    const requests = rows.filter((row) => row.type === "client-request");
    const load = requests.find((row) => row.method === "session/load");
    assert(load, "saved sidecar did not select session/load");
    assert(!requests.some((row) => row.method === "session/new"), "resume silently started a new session");
    assert(load.params.sessionId === "saved-session", "saved session id changed");
    assert(load.params.cwd === process.env.EXPECT_CWD, "load cwd changed");
    assert(Array.isArray(load.params.mcpServers) && load.params.mcpServers.length === 0, "load MCP list changed");
  '

  setup_case load-role-mismatch
  make_busy_writer "$CASE_ROOT"
  write_sidecar "$CASE_CWD" scout
  set +e
  printf '/exit\n' | run_bridge load-ok >"$CASE_OUT" 2>"$CASE_ERR"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "sidecar role mismatch must be refused"
  [ ! -s "$CASE_LOG" ] || fail "sidecar role mismatch started the child"
  assert_grep "failed:" "$CASE_STATE/task-3.status" "sidecar mismatch did not append a failure event"

  setup_case load-malformed
  make_busy_writer "$CASE_ROOT"
  printf '{"version":1,"sessionId":""}\n' >"$CASE_STATE/task-3.cursor-session.json"
  set +e
  printf '/exit\n' | run_bridge load-ok >"$CASE_OUT" 2>"$CASE_ERR"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "malformed existing sidecar must be refused"
  [ ! -s "$CASE_LOG" ] || fail "malformed sidecar silently started a new child session"
  assert_grep "--event preflight-error" "$CASE_BUSY_LOG" "malformed sidecar did not publish preflight unknown"
  assert_safe_status_file "$CASE_STATE/task-3.status" 1
  pass "Cursor ACP bridge resumes only an exact v1 cwd/role sidecar and refuses mismatches before child startup"
}

test_load_failure_is_loud_and_never_falls_back_to_new() {
  setup_case load-fail
  write_sidecar "$CASE_CWD" crew
  set +e
  printf '/exit\n' | run_bridge load-fail >"$CASE_OUT" 2>"$CASE_ERR"
  local rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "session/load error must make bridge exit non-zero"
  json_log_assert "$CASE_LOG" '
    const requests = rows.filter((row) => row.type === "client-request");
    assert(requests.some((row) => row.method === "session/load"), "load failure scenario never attempted load");
    assert(!requests.some((row) => row.method === "session/new"), "load failure silently fell back to session/new");
    assert(!requests.some((row) => row.method === "session/prompt"), "load failure still sent a prompt");
  '
  assert_grep "saved session unavailable" "$CASE_ERR" "load error diagnostic lost server message"
  assert_grep "failed:" "$CASE_STATE/task-3.status" "load error did not append failed status"
  pass "Cursor ACP session/load errors stop loudly, append failure, and never create a replacement session"
}

test_initialize_and_load_capability_are_explicit() {
  local scenario rc
  for scenario in initialize-missing-version initialize-wrong-version; do
    setup_case "$scenario"
    set +e
    printf '/exit\n' | run_bridge "$scenario" >"$CASE_OUT" 2>"$CASE_ERR"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$scenario must exit 1, got $rc"
    json_log_assert "$CASE_LOG" '
      const requests = rows.filter((row) => row.type === "client-request");
      assert(!requests.some((row) => row.method === "authenticate"), "invalid initialize still authenticated");
      assert(!requests.some((row) => row.method === "session/new"), "invalid initialize still created a session");
    '
    assert_grep "protocolVersion" "$CASE_ERR" "$scenario diagnostic omitted protocolVersion"
  done

  setup_case initialize-no-load
  write_sidecar "$CASE_CWD" crew
  set +e
  printf '/exit\n' | run_bridge initialize-no-load >"$CASE_OUT" 2>"$CASE_ERR"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "resume without loadSession capability must exit 1"
  json_log_assert "$CASE_LOG" '
    const requests = rows.filter((row) => row.type === "client-request");
    assert(!requests.some((row) => row.method === "session/load"), "load was called without advertised capability");
    assert(!requests.some((row) => row.method === "session/new"), "missing load capability silently created a session");
  '
  assert_grep "loadSession" "$CASE_ERR" "missing load capability diagnostic changed"
  assert_grep "--event protocol-error" "$CASE_BUSY_LOG" "missing load capability did not publish unknown"
  assert_safe_status_file "$CASE_STATE/task-3.status" 1
  pass "initialize explicitly negotiates protocol v1 and load requires advertised loadSession capability"
}

test_authentication_is_advertised_and_returns_object() {
  local scenario rc
  for scenario in initialize-missing-auth initialize-auth-methods-primitive; do
    setup_case "$scenario"
    set +e
    printf '/exit\n' | run_bridge "$scenario" >"$CASE_OUT" 2>"$CASE_ERR"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$scenario must exit 1, got $rc"
    json_log_assert "$CASE_LOG" '
      const requests = rows.filter((row) => row.type === "client-request");
      assert(!requests.some((row) => row.method === "authenticate"), "unadvertised auth was attempted");
      assert(!requests.some((row) => row.method === "session/new"), "unadvertised auth created a session");
    '
    assert_grep "authMethods" "$CASE_ERR" "$scenario auth advertisement diagnostic changed"
    assert_safe_status_file "$CASE_STATE/task-3.status" 1
  done

  setup_case authenticate-primitive
  set +e
  printf '/exit\n' | run_bridge authenticate-primitive >"$CASE_OUT" 2>"$CASE_ERR"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "primitive authenticate result must exit 1"
  json_log_assert "$CASE_LOG" '
    const requests = rows.filter((row) => row.type === "client-request");
    assert(requests.some((row) => row.method === "authenticate"), "authenticate was not attempted");
    assert(!requests.some((row) => row.method === "session/new"), "primitive auth result created a session");
    assert(!requests.some((row) => row.method === "session/load"), "primitive auth result loaded a session");
  '
  assert_grep "authenticate" "$CASE_ERR" "primitive authenticate result diagnostic changed"
  assert_safe_status_file "$CASE_STATE/task-3.status" 1
  pass "cursor_login must be advertised and authenticate must return an object"
}

test_load_sidecar_id_remains_authoritative() {
  setup_case load-mismatched-session
  write_sidecar "$CASE_CWD" crew
  set +e
  printf '/exit\n' | run_bridge load-mismatched-session >"$CASE_OUT" 2>"$CASE_ERR"
  local rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "load response replacement sessionId must exit 1"
  assert_grep "sessionId" "$CASE_ERR" "load replacement session diagnostic omitted sessionId"
  assert_no_grep " prompt-start" "$CASE_BUSY_LOG" "load replacement session still started prompt"
  assert_absent "$CASE_STATE/task-3.turn-ended" "load replacement session published turn end"
  pass "session/load cannot replace the sidecar's authoritative sessionId"
}

test_load_replay_is_bound_to_saved_session_before_response() {
  setup_case load-replay-correct
  write_sidecar "$CASE_CWD" crew
  printf '/exit\n' | run_bridge load-replay-correct >"$CASE_OUT" 2>"$CASE_ERR" \
    || fail "valid pre-load replay failed: $(cat "$CASE_ERR")"
  assert_grep "replay-before-load" "$CASE_OUT" "valid pre-load session/update was not rendered"
  json_log_assert "$CASE_LOG" '
    const permission = rows.find(
      (row) => row.type === "server-response" && row.id === "load-replay-permission",
    );
    assert(permission?.result?.outcome?.optionId === "allow-replay", "valid pre-load permission was not correlated");
    const load = rows.find((row) => row.type === "client-request" && row.method === "session/load");
    const prompt = rows.find((row) => row.type === "client-request" && row.method === "session/prompt");
    assert(load && prompt && load.id < prompt.id, "prompt did not wait for load completion");
  '

  local scenario rc
  for scenario in load-replay-wrong-update load-replay-wrong-permission; do
    setup_case "$scenario"
    write_sidecar "$CASE_CWD" crew
    set +e
    printf '/exit\n' | run_bridge "$scenario" >"$CASE_OUT" 2>"$CASE_ERR"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$scenario must exit 1, got $rc"
    assert_grep "sessionId mismatch" "$CASE_ERR" "$scenario mismatch diagnostic changed"
    assert_no_grep " prompt-start" "$CASE_BUSY_LOG" "$scenario started a prompt"
    assert_absent "$CASE_STATE/task-3.turn-ended" "$scenario fabricated a turn end"
    assert_safe_status_file "$CASE_STATE/task-3.status" 1
  done
  pass "session/load replay validates updates and permissions against the saved ID before load responds"
}

test_session_scoped_updates_and_permissions_match_current_session() {
  local scenario rc
  for scenario in update-session-mismatch permission-session-mismatch; do
    setup_case "$scenario"
    set +e
    printf '/exit\n' | run_bridge "$scenario" >"$CASE_OUT" 2>"$CASE_ERR"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$scenario must exit 1, got $rc"
    assert_grep "sessionId mismatch" "$CASE_ERR" "$scenario mismatch diagnostic changed"
    assert_no_grep " idle " "$CASE_BUSY_LOG" "$scenario published false idle"
    assert_absent "$CASE_STATE/task-3.turn-ended" "$scenario published false turn end"
    assert_safe_status_file "$CASE_STATE/task-3.status" 1
  done
  pass "session/update and permission requests reject replay from any other session"
}

test_permission_before_session_binding_is_rejected() {
  setup_case permission-before-session
  set +e
  printf '/exit\n' | run_bridge permission-before-session >"$CASE_OUT" 2>"$CASE_ERR"
  local rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "permission before session binding must exit 1, got $rc"
  assert_grep "session is not bound" "$CASE_ERR" \
    "early permission rejection did not name the unbound session"
  assert_no_grep " prompt-start" "$CASE_BUSY_LOG" \
    "early permission request still started a prompt"
  assert_absent "$CASE_STATE/task-3.turn-ended" \
    "early permission request fabricated a turn end"
  pass "permission requests are rejected until one authoritative session is bound"
}

test_permission_selection_uses_actual_server_options() {
  setup_case permission-allow
  printf '/exit\n' | run_bridge permission >"$CASE_OUT" 2>"$CASE_ERR" \
    || fail "allow permission scenario failed: $(cat "$CASE_ERR")"
  json_log_assert "$CASE_LOG" '
    const response = rows.find((row) => row.type === "server-response" && row.id === "perm-allow");
    assert(response, "permission response missing");
    assert(response.result.outcome.outcome === "selected", "allow option was not selected");
    assert(response.result.outcome.optionId === "once-actual", "allow_once did not win using its real optionId");
  '

  setup_case permission-reject
  printf '/exit\n' | run_bridge permission-no-allow >"$CASE_OUT" 2>"$CASE_ERR" \
    || fail "reject permission scenario failed: $(cat "$CASE_ERR")"
  json_log_assert "$CASE_LOG" '
    const response = rows.find((row) => row.type === "server-response" && row.id === "perm-reject");
    assert(response.result.outcome.outcome === "selected", "real reject option was not selected");
    assert(response.result.outcome.optionId === "deny-once-real", "reject_once did not win using its real optionId");
  '
  assert_grep "blocked: Cursor ACP permission request offered no allow option: Unsafe command" \
    "$CASE_STATE/task-3.status" "no-allow permission did not append exact blocked escalation"

  setup_case permission-always-only
  printf '/exit\n' | run_bridge permission-always-only >"$CASE_OUT" 2>"$CASE_ERR" \
    || fail "allow_always-only permission scenario failed: $(cat "$CASE_ERR")"
  json_log_assert "$CASE_LOG" '
    const response = rows.find(
      (row) => row.type === "server-response" && row.id === "perm-always-only",
    );
    assert(response.result.outcome.outcome === "selected", "real reject option was not selected");
    assert(
      response.result.outcome.optionId === "reject-always-only",
      "allow_always must never be selected automatically",
    );
  '
  assert_grep "blocked: Cursor ACP permission request offered no allow option: Persistent permission" \
    "$CASE_STATE/task-3.status" "allow_always-only request did not escalate"

  setup_case permission-none
  printf '/exit\n' | run_bridge permission-no-options >"$CASE_OUT" 2>"$CASE_ERR" \
    || fail "empty permission scenario failed: $(cat "$CASE_ERR")"
  json_log_assert "$CASE_LOG" '
    const response = rows.find((row) => row.type === "server-response" && row.id === "perm-none");
    assert(response.result.outcome.outcome === "cancelled", "empty permission options must cancel");
  '
  pass "Cursor ACP permission decisions prefer real allow_once IDs, then real rejects, then cancellation with escalation"
}

test_permission_requests_require_acp_v1_tool_call_shape() {
  local scenario rc
  for scenario in \
    permission-missing-tool-call-id \
    permission-options-primitive \
    permission-option-malformed
  do
    setup_case "$scenario"
    set +e
    printf '/exit\n' | run_bridge "$scenario" >"$CASE_OUT" 2>"$CASE_ERR"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$scenario must exit 1, got $rc"
    assert_grep "permission" "$CASE_ERR" "$scenario permission diagnostic changed"
    assert_no_grep " idle " "$CASE_BUSY_LOG" "$scenario published false idle"
    assert_absent "$CASE_STATE/task-3.turn-ended" "$scenario fabricated a turn end"
    assert_safe_status_file "$CASE_STATE/task-3.status" 1
  done
  pass "permission requests require sessionId, toolCallId, and typed option identifiers"
}

test_cursor_extensions_escalate_and_blocking_ids_are_correlated() {
  setup_case extensions
  printf '/exit\n' | run_bridge extensions >"$CASE_OUT" 2>"$CASE_ERR" \
    || fail "Cursor extension scenario failed: $(cat "$CASE_ERR")"
  json_log_assert "$CASE_LOG" '
    const ask = rows.find((row) => row.type === "server-response" && row.id === "ask-string");
    const plan = rows.find((row) => row.type === "server-response" && row.id === 0);
    assert(ask && ask.result.outcome.outcome === "skipped", "ask_question must be skipped");
    assert(ask.result.outcome.reason.includes("Firstmate status protocol"), "ask_question reason did not explain escalation");
    assert(plan && plan.result.outcome.outcome === "rejected", "create_plan id=0 must be rejected");
    assert(plan.result.outcome.reason.includes("Firstmate status protocol"), "create_plan reason did not explain escalation");
  '
  assert_grep "needs-decision: Cursor requested interactive question Choose deployment; inspect the worker pane" \
    "$CASE_STATE/task-3.status" "ask_question escalation status changed"
  assert_grep "needs-decision: Cursor requested plan approval Refactor safely; inspect the worker pane" \
    "$CASE_STATE/task-3.status" "create_plan escalation status changed"
  assert_grep "[cursor:update_todos]" "$CASE_OUT" "todo notification lacks stable rendering"
  assert_grep "[cursor:task]" "$CASE_OUT" "task notification lacks stable rendering"
  assert_grep "[cursor:generate_image]" "$CASE_OUT" "image notification lacks stable rendering"
  pass "Cursor blocking extensions escalate through Firstmate and notification extensions render without responses"
}

test_cursor_extensions_accept_official_optional_labels_and_nested_shapes() {
  setup_case extensions-optional-labels
  printf '/exit\n' | run_bridge extensions-optional-labels >"$CASE_OUT" 2>"$CASE_ERR" \
    || fail "Cursor optional extension fields failed: $(cat "$CASE_ERR")"
  json_log_assert "$CASE_LOG" '
    const ask = rows.find(
      (row) => row.type === "server-response" && row.id === "ask-optional-title",
    );
    const plan = rows.find(
      (row) => row.type === "server-response" && row.id === "plan-optional-name",
    );
    assert(ask?.result?.outcome?.outcome === "skipped", "optional ask title was rejected");
    assert(plan?.result?.outcome?.outcome === "rejected", "optional plan name was rejected");
  '
  assert_grep "needs-decision: Cursor requested interactive question Untitled question" \
    "$CASE_STATE/task-3.status" "missing optional ask title lacked safe fallback"
  assert_grep "needs-decision: Cursor requested plan approval Untitled plan" \
    "$CASE_STATE/task-3.status" "missing optional plan name lacked safe fallback"
  pass "Cursor extension validation accepts official optional labels and typed nested fields"
}

test_cursor_blocking_extensions_require_correlated_shapes() {
  local scenario rc
  for scenario in \
    extension-ask-malformed \
    extension-ask-bad-question \
    extension-plan-malformed \
    extension-plan-bad-todo
  do
    setup_case "$scenario"
    set +e
    printf '/exit\n' | run_bridge "$scenario" >"$CASE_OUT" 2>"$CASE_ERR"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$scenario must exit 1, got $rc"
    assert_grep "Cursor extension" "$CASE_ERR" \
      "$scenario malformed extension diagnostic changed"
    assert_no_grep "needs-decision:" "$CASE_STATE/task-3.status" \
      "$scenario published an uncorrelated decision escalation"
    assert_no_grep " idle " "$CASE_BUSY_LOG" "$scenario published false idle"
    assert_absent "$CASE_STATE/task-3.turn-ended" "$scenario fabricated a turn end"
  done
  pass "Cursor blocking extensions require typed correlation before escalation"
}
test_unknown_server_request_gets_method_not_found() {
  setup_case unknown-request
  printf '/exit\n' | run_bridge unknown-request >"$CASE_OUT" 2>"$CASE_ERR" \
    || fail "unknown server request scenario failed: $(cat "$CASE_ERR")"
  json_log_assert "$CASE_LOG" '
    const response = rows.find((row) => row.type === "server-response" && row.id === 77);
    assert(response, "unknown server request received no response");
    assert(response.error && response.error.code === -32601, "unknown server request did not receive JSON-RPC method not found");
  '
  pass "Cursor ACP bridge returns -32601 for unknown server requests so the server cannot hang"
}

test_jsonrpc_null_id_and_structured_params_details() {
  setup_case jsonrpc-null-id
  printf '/exit\n' | run_bridge null-id-request >"$CASE_OUT" 2>"$CASE_ERR" \
    || fail "JSON-RPC null request id failed: $(cat "$CASE_ERR")"
  json_log_assert "$CASE_LOG" '
    const response = rows.find((row) => row.type === "server-response" && row.id === null);
    assert(response, "missing response correlated with id:null");
    assert(response.error?.code === -32601, "id:null unknown request did not receive -32601");
  '

  local scenario rc
  for scenario in fractional-error-code primitive-params; do
    setup_case "$scenario"
    set +e
    printf '/exit\n' | run_bridge "$scenario" >"$CASE_OUT" 2>"$CASE_ERR"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$scenario must exit 1, got $rc"
    assert_grep "invalid JSON-RPC" "$CASE_ERR" "$scenario protocol diagnostic changed"
    assert_absent "$CASE_STATE/task-3.turn-ended" "$scenario fabricated a turn end"
    assert_safe_status_file "$CASE_STATE/task-3.status" 1
  done
  pass "JSON-RPC accepts id:null while rejecting fractional error codes and primitive params"
}

assert_safe_status_file() { # <path> <line-count>
  node --input-type=module - "$1" "$2" <<'JS'
import fs from "node:fs";
const [statusPath, countText] = process.argv.slice(2);
const raw = fs.readFileSync(statusPath, "utf8");
const lines = raw.endsWith("\n") ? raw.slice(0, -1).split("\n") : raw.split("\n");
if (lines.length !== Number(countText)) {
  throw new Error(`expected ${countText} status lines, got ${lines.length}: ${JSON.stringify(lines)}`);
}
for (const line of lines) {
  if (!/^(failed|blocked|needs-decision): /.test(line)) {
    throw new Error(`unowned status prefix: ${JSON.stringify(line)}`);
  }
  if (/[\u0000-\u001f\u007f]/.test(line)) {
    throw new Error(`control character in status line: ${JSON.stringify(line)}`);
  }
  if (line.length > 1000) {
    throw new Error(`status line exceeds 1000 characters: ${line.length}`);
  }
}
if (lines.some((line) => /^done: forged/.test(line))) {
  throw new Error("external text forged a recognizable status line");
}
JS
}

test_status_appends_are_single_line_sanitized_and_bounded() {
  local rc sidecar
  setup_case status-title-injection
  printf '/exit\n' | run_bridge status-injection >"$CASE_OUT" 2>"$CASE_ERR" \
    || fail "status title injection scenario failed: $(cat "$CASE_ERR")"
  assert_safe_status_file "$CASE_STATE/task-3.status" 3

  setup_case status-rpc-injection
  set +e
  printf '/exit\n' | run_bridge rpc-error-injection >"$CASE_OUT" 2>"$CASE_ERR"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "RPC error injection must fail with exit 1"
  assert_safe_status_file "$CASE_STATE/task-3.status" 1

  setup_case status-sidecar-injection
  sidecar="$CASE_STATE/task-3.cursor-session.json"
  SIDECAR="$sidecar" node --input-type=module <<'JS'
import fs from "node:fs";
fs.writeFileSync(process.env.SIDECAR, JSON.stringify({
  version: 1,
  sessionId: "saved-session",
  cwd: "/forged\ndone: forged\t\u007f",
  role: "crew",
  updatedAt: "2026-08-02T00:00:00.000Z",
}) + "\n", { mode: 0o600 });
JS
  set +e
  printf '/exit\n' | run_bridge load-ok >"$CASE_OUT" 2>"$CASE_ERR"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "sidecar mismatch injection must fail with exit 1"
  assert_safe_status_file "$CASE_STATE/task-3.status" 1
  pass "status writes sanitize controls and whitespace, enforce owned prefixes, and cap each event"
}

test_protocol_failures_are_nonzero_and_publish_unknown() {
  local scenario expected event rc
  for scenario in invalid-json unknown-id child-eof rpc-error child-exit; do
    setup_case "fatal-$scenario"
    set +e
    printf '/exit\n' | run_bridge "$scenario" >"$CASE_OUT" 2>"$CASE_ERR"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$scenario must exit non-zero"
    [ -s "$CASE_ERR" ] || fail "$scenario did not print a clear error"
    case "$scenario" in
      invalid-json) expected="invalid JSON"; event=protocol-error ;;
      unknown-id) expected="unknown response id"; event=protocol-error ;;
      child-eof) expected="stdout EOF"; event=protocol-error ;;
      rpc-error) expected="initialize refused"; event=protocol-error ;;
      child-exit) expected="exited"; event=process-exit ;;
    esac
    assert_grep "$expected" "$CASE_ERR" "$scenario error diagnostic is not explicit"
    assert_grep "--event $event" "$CASE_BUSY_LOG" "$scenario did not publish unknown/$event"
    assert_grep "failed:" "$CASE_STATE/task-3.status" "$scenario did not append a failed event"
  done
  pass "invalid JSON, unknown response IDs, child EOF/error responses, and unexpected exit all fail explicitly"
}

test_incoming_jsonrpc_envelopes_are_strict_v2() {
  local scenario rc
  for scenario in missing-jsonrpc both-result-error bad-error-shape bad-response-id bad-method; do
    setup_case "jsonrpc-$scenario"
    set +e
    printf '/exit\n' | run_bridge "$scenario" >"$CASE_OUT" 2>"$CASE_ERR"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$scenario JSON-RPC envelope must exit 1, got $rc"
    assert_grep "JSON-RPC" "$CASE_ERR" "$scenario lacks an explicit JSON-RPC diagnostic"
    assert_no_grep " idle " "$CASE_BUSY_LOG" "$scenario published false idle"
    assert_absent "$CASE_STATE/task-3.turn-ended" "$scenario published false turn end"
    assert_grep "--event protocol-error" "$CASE_BUSY_LOG" "$scenario did not publish protocol-error"
    assert_safe_status_file "$CASE_STATE/task-3.status" 1
  done
  pass "incoming messages require strict JSON-RPC 2.0 method, id, and response/error envelopes"
}

test_prompt_result_requires_exact_v1_stop_reason() {
  local scenario rc stop
  for scenario in prompt-null prompt-empty prompt-unknown-stop; do
    setup_case "$scenario"
    set +e
    printf '/exit\n' | run_bridge "$scenario" >"$CASE_OUT" 2>"$CASE_ERR"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$scenario must exit 1, got $rc"
    assert_no_grep " idle " "$CASE_BUSY_LOG" "$scenario published false idle"
    assert_absent "$CASE_STATE/task-3.turn-ended" "$scenario published false turn end"
    assert_grep "--event protocol-error" "$CASE_BUSY_LOG" "$scenario did not publish unknown"
    assert_grep "failed:" "$CASE_STATE/task-3.status" "$scenario did not append failed status"
  done
  for stop in end_turn max_tokens max_turn_requests refusal cancelled; do
    setup_case "valid-stop-$stop"
    printf '/exit\n' | run_bridge "stop-$stop" >"$CASE_OUT" 2>"$CASE_ERR" \
      || fail "valid ACP v1 stopReason $stop was rejected: $(cat "$CASE_ERR")"
    assert_grep " idle --gen gen-3 --source cursor-acp --event prompt-stop" \
      "$CASE_BUSY_LOG" "valid stopReason $stop did not complete the turn"
    assert_present "$CASE_STATE/task-3.turn-ended" "valid stopReason $stop lost turn end"
  done
  pass "prompt responses require an object and one exact ACP v1 stopReason"
}

test_cancel_requires_cancelled_stop_reason() {
  setup_case cancel-wrong-stop
  make_busy_writer "$CASE_ROOT"
  local fifo="$CASE_ROOT/stdin.fifo" pid tries=0
  mkfifo "$fifo"
  env FM_FAKE_ACP_SCENARIO=signal-wrong-stop FM_FAKE_ACP_LOG="$CASE_LOG" \
    FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    node "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      <"$fifo" >"$CASE_OUT" 2>"$CASE_ERR" &
  pid=$!
  ACTIVE_PIDS="$ACTIVE_PIDS $pid"
  exec 9>"$fifo"
  while [ "$tries" -lt 200 ]; do
    if [ -f "$CASE_LOG" ] && grep -q '"type":"signal-ready"' "$CASE_LOG"; then
      break
    fi
    tries=$((tries + 1))
    sleep 0.02
  done
  [ "$tries" -lt 200 ] || fail "wrong-stop cancellation never reached active prompt"
  kill -INT "$pid"
  exec 9>&-
  wait_bounded_exit "$pid" 200 || fail "wrong-stop cancellation exceeded bound"
  ACTIVE_PIDS=${ACTIVE_PIDS// $pid/}
  [ "$BOUNDED_RC" -eq 1 ] \
    || fail "non-cancelled result after session/cancel must exit 1, got $BOUNDED_RC"
  assert_no_grep " idle " "$CASE_BUSY_LOG" "wrong cancel stop published false idle"
  assert_absent "$CASE_STATE/task-3.turn-ended" "wrong cancel stop published false turn end"
  assert_grep "failed:" "$CASE_STATE/task-3.status" "wrong cancel stop did not append failed"
  pass "a bridge-issued session/cancel accepts only stopReason=cancelled"
}

test_sigint_cancels_prompt_and_permission_then_stays_reusable() {
  setup_case sigint
  make_busy_writer "$CASE_ROOT"
  local fifo="$CASE_ROOT/stdin.fifo" pid rc tries=0
  mkfifo "$fifo"
  env FM_FAKE_ACP_SCENARIO=signal-cancel FM_FAKE_ACP_LOG="$CASE_LOG" \
    FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    node "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      <"$fifo" >"$CASE_OUT" 2>"$CASE_ERR" &
  pid=$!
  ACTIVE_PIDS="$ACTIVE_PIDS $pid"
  exec 9>"$fifo"
  while [ "$tries" -lt 200 ]; do
    if [ -f "$CASE_LOG" ] && grep -q '"type":"signal-ready"' "$CASE_LOG"; then
      break
    fi
    tries=$((tries + 1))
    sleep 0.02
  done
  [ "$tries" -lt 200 ] || fail "signal scenario never reached an active prompt"
  kill -INT "$pid"
  tries=0
  while [ "$tries" -lt 200 ]; do
    if grep -q '"method":"session/cancel"' "$CASE_LOG" 2>/dev/null \
      && grep -q ' idle --gen gen-3 --source cursor-acp --event prompt-stop' "$CASE_BUSY_LOG" 2>/dev/null; then
      break
    fi
    tries=$((tries + 1))
    sleep 0.02
  done
  [ "$tries" -lt 200 ] || fail "SIGINT cancellation did not settle the cancelled turn"
  kill -0 "$pid" 2>/dev/null \
    || fail "SIGINT exited the bridge instead of returning it to idle"
  printf 'after cancellation\n' >&9
  wait_for_prompt_count "$CASE_LOG" 2 \
    || fail "bridge did not process a second prompt after SIGINT cancellation"
  tries=0
  while [ "$tries" -lt 200 ]; do
    [ "$(grep -c ' prompt-stop$' "$CASE_BUSY_LOG" 2>/dev/null || true)" -ge 2 ] && break
    tries=$((tries + 1))
    sleep 0.02
  done
  [ "$tries" -lt 200 ] || fail "second prompt did not complete after cancellation"
  sleep 2.2
  kill -0 "$pid" 2>/dev/null \
    || fail "a stale cancellation timeout killed the reusable bridge"
  printf '/exit\n' >&9
  exec 9>&-
  set +e
  wait "$pid"
  rc=$?
  set -e
  ACTIVE_PIDS=${ACTIVE_PIDS// $pid/}
  [ "$rc" -eq 0 ] || fail "SIGINT cancellation did not exit cleanly: $(cat "$CASE_ERR")"
  json_log_assert "$CASE_LOG" '
    const cancel = rows.find((row) => row.type === "client-notification" && row.method === "session/cancel");
    assert(cancel && cancel.params.sessionId === "session-new-123", "SIGINT did not send session/cancel");
    const permission = rows.find((row) => row.type === "server-response" && row.id === 0);
    assert(permission && permission.result.outcome.outcome === "cancelled", "permission during cancellation was not cancelled");
    const prompts = rows.filter((row) => row.type === "prompt");
    assert(prompts.length === 2, `expected cancelled prompt plus reusable prompt, got ${prompts.length}`);
    assert(prompts[1].params.prompt[0].text === "after cancellation", "second prompt text changed");
  '
  [ "$(grep -c ' prompt-stop$' "$CASE_BUSY_LOG")" -eq 2 ] \
    || fail "cancelled and follow-up prompts must each publish idle"
  assert_present "$CASE_STATE/task-3.turn-ended" "cancelled prompt did not publish turn end"
  [ ! -s "$CASE_STATE/task-3.status" ] 2>/dev/null \
    || fail "normal SIGINT cancellation appended a false failure"
  pass "SIGINT cancels one ACP prompt, clears its timeout, and leaves the bridge reusable"
}

test_termination_signal_upgrades_an_unanswered_sigint_cancel() {
  local signal
  for signal in TERM HUP; do
    setup_case "cancel-upgrade-$signal"
    make_busy_writer "$CASE_ROOT"
    local fifo="$CASE_ROOT/stdin.fifo" pid tries=0
    mkfifo "$fifo"
    env FM_FAKE_ACP_SCENARIO=signal-cancel-no-response FM_FAKE_ACP_LOG="$CASE_LOG" \
      FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
      node "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
        --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
        <"$fifo" >"$CASE_OUT" 2>"$CASE_ERR" &
    pid=$!
    ACTIVE_PIDS="$ACTIVE_PIDS $pid"
    exec 9>"$fifo"
    printf 'cancel then terminate\n' >&9
    while [ "$tries" -lt 200 ]; do
      grep -q '"type":"signal-ready"' "$CASE_LOG" 2>/dev/null && break
      tries=$((tries + 1))
      sleep 0.02
    done
    [ "$tries" -lt 200 ] || fail "$signal upgrade never reached active prompt"
    kill -INT "$pid"
    tries=0
    while [ "$tries" -lt 200 ]; do
      grep -q '"method":"session/cancel"' "$CASE_LOG" 2>/dev/null && break
      tries=$((tries + 1))
      sleep 0.02
    done
    [ "$tries" -lt 200 ] || fail "$signal upgrade did not first send session/cancel"
    kill "-$signal" "$pid"
    exec 9>&-
    wait_bounded_exit "$pid" 300 \
      || fail "$signal did not bound shutdown after unanswered SIGINT cancellation"
    ACTIVE_PIDS=${ACTIVE_PIDS// $pid/}
    [ "$BOUNDED_RC" -eq 0 ] \
      || fail "$signal after SIGINT cancellation exited $BOUNDED_RC instead of cleanly"
    assert_no_grep "^failed:" "$CASE_STATE/task-3.status" \
      "$signal escalation appended a false failed status"
    assert_no_grep "--event protocol-error" "$CASE_BUSY_LOG" \
      "$signal escalation published a false protocol error"
  done
  pass "SIGTERM and SIGHUP upgrade unanswered SIGINT cancellation to bounded clean shutdown"
}

test_signal_during_busy_publication_aborts_before_prompt() {
  local signal pid rc tries fifo sync
  for signal in TERM; do
    setup_case "publishing-$signal"
    make_busy_writer "$CASE_ROOT"
    fifo="$CASE_ROOT/stdin.fifo"
    sync="$CASE_ROOT/busy-sync"
    mkdir -p "$sync"
    mkfifo "$fifo"
    env FM_FAKE_ACP_SCENARIO=happy FM_FAKE_ACP_LOG="$CASE_LOG" \
      FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" FM_FAKE_BUSY_BLOCK_DIR="$sync" \
      FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
      node "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
        --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
        <"$fifo" >"$CASE_OUT" 2>"$CASE_ERR" &
    pid=$!
    ACTIVE_PIDS="$ACTIVE_PIDS $pid"
    exec 9>"$fifo"
    tries=0
    while [ "$tries" -lt 200 ] && [ ! -e "$sync/entered" ]; do
      tries=$((tries + 1))
      sleep 0.02
    done
    [ -e "$sync/entered" ] || fail "$signal scenario never blocked in publishing-busy"
    kill "-$signal" "$pid"
    : >"$sync/release"
    exec 9>&-
    wait_bounded_exit "$pid" 200 \
      || fail "$signal during publishing-busy exceeded bounded cleanup"
    rc=$BOUNDED_RC
    ACTIVE_PIDS=${ACTIVE_PIDS// $pid/}
    [ "$rc" -eq 0 ] || fail "$signal during publishing-busy must exit cleanly, got $rc"
    json_log_assert "$CASE_LOG" '
      assert(!rows.some((row) => row.type === "prompt"), "signal after busy publication still sent session/prompt");
    '
    assert_grep " busy --gen gen-3 --source cursor-acp --event prompt-start" \
      "$CASE_BUSY_LOG" "$signal did not finish publishing busy"
    assert_grep " idle --gen gen-3 --source cursor-acp --event prompt-abort" \
      "$CASE_BUSY_LOG" "$signal did not compensate busy with idle/prompt-abort"
    assert_no_grep "prompt-stop" "$CASE_BUSY_LOG" "$signal emitted a false prompt-stop"
    assert_absent "$CASE_STATE/task-3.turn-ended" "$signal emitted a false turn-ended marker"
    [ ! -s "$CASE_STATE/task-3.status" ] 2>/dev/null \
      || fail "$signal publishing abort appended a false failure"
  done
  pass "SIGTERM during busy publication compensates idle without sending a prompt or turn end"
}

test_sigint_during_busy_publication_returns_to_reusable_idle() {
  setup_case publishing-int-reuse
  make_busy_writer "$CASE_ROOT"
  local fifo="$CASE_ROOT/stdin.fifo" sync="$CASE_ROOT/busy-sync"
  local pid rc tries=0
  mkdir -p "$sync"
  mkfifo "$fifo"
  env FM_FAKE_ACP_SCENARIO=happy FM_FAKE_ACP_LOG="$CASE_LOG" \
    FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" FM_FAKE_BUSY_BLOCK_DIR="$sync" \
    FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    node "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      <"$fifo" >"$CASE_OUT" 2>"$CASE_ERR" &
  pid=$!
  ACTIVE_PIDS="$ACTIVE_PIDS $pid"
  exec 9>"$fifo"
  while [ "$tries" -lt 200 ] && [ ! -e "$sync/entered" ]; do
    tries=$((tries + 1))
    sleep 0.02
  done
  [ -e "$sync/entered" ] || fail "SIGINT reuse case never blocked in publishing-busy"
  kill -INT "$pid"
  : >"$sync/release"
  tries=0
  while [ "$tries" -lt 200 ]; do
    grep -q ' prompt-abort$' "$CASE_BUSY_LOG" 2>/dev/null && break
    tries=$((tries + 1))
    sleep 0.02
  done
  [ "$tries" -lt 200 ] || fail "SIGINT publishing abort did not compensate idle"
  kill -0 "$pid" 2>/dev/null \
    || fail "SIGINT during busy publication exited the bridge"
  printf 'after publishing abort\n' >&9
  wait_for_prompt_count "$CASE_LOG" 1 \
    || fail "bridge did not accept a prompt after publishing-busy SIGINT"
  printf '/exit\n' >&9
  exec 9>&-
  set +e
  wait "$pid"
  rc=$?
  set -e
  ACTIVE_PIDS=${ACTIVE_PIDS// $pid/}
  [ "$rc" -eq 0 ] || fail "publishing-busy SIGINT reuse run failed: $(cat "$CASE_ERR")"
  json_log_assert "$CASE_LOG" '
    const prompts = rows.filter((row) => row.type === "prompt");
    assert(prompts.length === 1, `expected only the post-abort prompt, got ${prompts.length}`);
    assert(prompts[0].params.prompt[0].text === "after publishing abort", "post-abort prompt text changed");
  '
  pass "SIGINT during busy publication aborts only that prompt and returns to reusable idle"
}

test_terminal_group_sigint_does_not_kill_busy_helper() {
  setup_case group-sigint-busy-helper
  make_busy_writer "$CASE_ROOT"
  local sync="$CASE_ROOT/busy-sync" helper_pid_file="$CASE_ROOT/busy-helper.pid"
  mkdir -p "$sync"
  MODE=group-sigint NODE_BIN="$NODE_BIN" BRIDGE="$BRIDGE" FAKE_AGENT="$FAKE_AGENT" \
    CASE_CWD="$CASE_CWD" CASE_STATE="$CASE_STATE" CASE_BRIEF="$CASE_BRIEF" \
    CASE_LOG="$CASE_LOG" CASE_BUSY_LOG="$CASE_BUSY_LOG" BUSY_WRITER="$BUSY_WRITER" \
    CASE_OUT="$CASE_OUT" CASE_ERR="$CASE_ERR" SYNC="$sync" \
    HELPER_PID_FILE="$helper_pid_file" python3 <<'PY' \
    || fail "terminal-style group SIGINT killed the busy helper or bridge: $(cat "$CASE_ERR")"
import json
import os
import signal
import subprocess
import time

env = os.environ.copy()
env.update({
    "FM_FAKE_ACP_SCENARIO": "happy",
    "FM_FAKE_ACP_LOG": env["CASE_LOG"],
    "FM_FAKE_BUSY_LOG": env["CASE_BUSY_LOG"],
    "FM_CURSOR_BUSY_EVENT": env["BUSY_WRITER"],
    "FM_FAKE_BUSY_BLOCK_DIR": env["SYNC"],
    "FM_FAKE_BUSY_BLOCK_STATE": "busy",
    "FM_FAKE_BUSY_PID_FILE": env["HELPER_PID_FILE"],
})
argv = [
    env["NODE_BIN"], env["BRIDGE"],
    "--cwd", env["CASE_CWD"],
    "--task-id", "task-3",
    "--state-dir", env["CASE_STATE"],
    "--brief", env["CASE_BRIEF"],
    "--busy-gen", "gen-3",
    "--agent-bin", env["FAKE_AGENT"],
]
with open(env["CASE_OUT"], "wb") as stdout, open(env["CASE_ERR"], "wb") as stderr:
    process = subprocess.Popen(
        argv,
        stdin=subprocess.PIPE,
        stdout=stdout,
        stderr=stderr,
        env=env,
        start_new_session=True,
    )
    def wait_for(predicate, seconds=5):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return True
            if process.poll() is not None:
                return False
            time.sleep(0.02)
        return False
    try:
        if not wait_for(lambda: os.path.exists(os.path.join(env["SYNC"], "entered"))
                        and os.path.exists(env["HELPER_PID_FILE"])):
            raise RuntimeError("busy helper never entered prompt-start publication")
        helper_pid = int(open(env["HELPER_PID_FILE"], encoding="utf-8").read().strip())
        bridge_pgid = os.getpgid(process.pid)
        helper_pgid = os.getpgid(helper_pid)
        os.killpg(bridge_pgid, signal.SIGINT)
        time.sleep(0.15)
        helper_alive = True
        try:
            stat = subprocess.check_output(
                ["ps", "-o", "stat=", "-p", str(helper_pid)],
                text=True,
            ).strip()
            helper_alive = bool(stat) and not stat.startswith("Z")
        except (OSError, subprocess.CalledProcessError):
            helper_alive = False
        open(os.path.join(env["SYNC"], "release"), "w", encoding="utf-8").close()
        if helper_pgid == bridge_pgid or not helper_alive:
            raise RuntimeError(
                f"busy helper shared/killed by bridge PGID: bridge={bridge_pgid} helper={helper_pgid}"
            )
        if not wait_for(lambda: os.path.exists(env["CASE_BUSY_LOG"])
                        and " prompt-abort\n" in open(env["CASE_BUSY_LOG"], encoding="utf-8").read()):
            raise RuntimeError("bridge did not publish prompt-abort after group SIGINT")
        process.stdin.write(b"group C-c Enter\n")
        process.stdin.flush()
        def followup_arrived():
            if not os.path.exists(env["CASE_LOG"]):
                return False
            rows = [
                json.loads(line)
                for line in open(env["CASE_LOG"], encoding="utf-8")
                if line.strip()
            ]
            prompts = [row for row in rows if row.get("type") == "prompt"]
            return bool(prompts) and prompts[-1]["params"]["prompt"][0]["text"] == "group C-c Enter"
        if not wait_for(followup_arrived):
            raise RuntimeError("bridge was not reusable after terminal group SIGINT")
        process.stdin.write(b"/exit\n")
        process.stdin.flush()
        if process.wait(timeout=6) != 0:
            raise RuntimeError("bridge did not exit cleanly after group SIGINT reuse")
    except Exception:
        open(os.path.join(env["SYNC"], "release"), "w", encoding="utf-8").close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        raise
PY
  assert_no_grep '"method":"session/cancel"' "$CASE_LOG" \
    "publishing-busy group SIGINT incorrectly sent session/cancel"
  pass "terminal process-group SIGINT reaches the bridge without killing its busy-event helper"
}

test_sigint_during_idle_publication_is_a_reusable_noop() {
  setup_case publishing-idle-int
  make_busy_writer "$CASE_ROOT"
  local fifo="$CASE_ROOT/stdin.fifo" sync="$CASE_ROOT/idle-sync"
  local pid rc tries=0
  mkdir -p "$sync"
  mkfifo "$fifo"
  env FM_FAKE_ACP_SCENARIO=happy FM_FAKE_ACP_LOG="$CASE_LOG" \
    FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" FM_FAKE_BUSY_BLOCK_DIR="$sync" \
    FM_FAKE_BUSY_BLOCK_STATE=idle FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    node "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      <"$fifo" >"$CASE_OUT" 2>"$CASE_ERR" &
  pid=$!
  ACTIVE_PIDS="$ACTIVE_PIDS $pid"
  exec 9>"$fifo"
  while [ "$tries" -lt 200 ] && [ ! -e "$sync/entered" ]; do
    tries=$((tries + 1))
    sleep 0.02
  done
  [ -e "$sync/entered" ] || fail "prompt-stop writer never blocked in idle publication"
  kill -INT "$pid"
  sleep 2.2
  kill -0 "$pid" 2>/dev/null \
    || fail "SIGINT during idle publication armed a late fatal timeout"
  assert_no_grep '"method":"session/cancel"' "$CASE_LOG" \
    "SIGINT after prompt RPC completion sent session/cancel"
  : >"$sync/release"
  tries=0
  while [ "$tries" -lt 200 ] && [ ! -e "$CASE_STATE/task-3.turn-ended" ]; do
    tries=$((tries + 1))
    sleep 0.02
  done
  [ -e "$CASE_STATE/task-3.turn-ended" ] || fail "idle publication did not finish after release"
  printf 'after idle publication\n' >&9
  wait_for_prompt_count "$CASE_LOG" 2 \
    || fail "bridge did not process a second prompt after idle-publication SIGINT"
  printf '/exit\n' >&9
  exec 9>&-
  set +e
  wait "$pid"
  rc=$?
  set -e
  ACTIVE_PIDS=${ACTIVE_PIDS// $pid/}
  [ "$rc" -eq 0 ] || fail "idle-publication SIGINT reuse run failed: $(cat "$CASE_ERR")"
  json_log_assert "$CASE_LOG" '
    const prompts = rows.filter((row) => row.type === "prompt");
    assert(prompts.length === 2, `expected two prompts after idle publication, got ${prompts.length}`);
    assert(prompts[1].params.prompt[0].text === "after idle publication", "second prompt text changed");
    assert(!rows.some((row) => row.type === "client-notification" && row.method === "session/cancel"), "idle publication sent session/cancel");
  '
  pass "SIGINT during prompt-stop publication is a no-op with no late fatal and bridge reuse"
}

test_acp_child_has_an_isolated_process_group() {
  setup_case isolated-child-group
  make_busy_writer "$CASE_ROOT"
  local fifo="$CASE_ROOT/stdin.fifo" pid child_pid bridge_pgid child_pgid tries=0
  mkfifo "$fifo"
  env FM_FAKE_ACP_SCENARIO=startup-hang FM_FAKE_ACP_LOG="$CASE_LOG" \
    FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    node "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      <"$fifo" >"$CASE_OUT" 2>"$CASE_ERR" &
  pid=$!
  ACTIVE_PIDS="$ACTIVE_PIDS $pid"
  exec 9>"$fifo"
  while [ "$tries" -lt 200 ]; do
    grep -q '"type":"spawn"' "$CASE_LOG" 2>/dev/null && break
    tries=$((tries + 1))
    sleep 0.02
  done
  [ "$tries" -lt 200 ] || fail "isolated child case never spawned"
  child_pid=$(node -e '
    const fs=require("fs");
    const rows=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);
    process.stdout.write(String(rows.find((row)=>row.type==="spawn").pid));
  ' "$CASE_LOG")
  bridge_pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
  child_pgid=$(ps -o pgid= -p "$child_pid" | tr -d ' ')
  if [ -z "$child_pgid" ] || [ "$child_pgid" != "$child_pid" ] || [ "$child_pgid" = "$bridge_pgid" ]; then
    kill -TERM "$pid" "$child_pid" 2>/dev/null || true
    exec 9>&-
    wait "$pid" 2>/dev/null || true
    ACTIVE_PIDS=${ACTIVE_PIDS// $pid/}
    fail "ACP child was not isolated from terminal SIGINT process groups (bridge=$bridge_pgid child=$child_pgid pid=$child_pid)"
  fi
  kill -TERM "$pid"
  exec 9>&-
  wait_bounded_exit "$pid" 200 || fail "isolated child cleanup exceeded bound"
  ACTIVE_PIDS=${ACTIVE_PIDS// $pid/}
  [ "$BOUNDED_RC" -eq 0 ] || fail "isolated child SIGTERM cleanup must exit 0"
  ! kill -0 "$child_pid" 2>/dev/null \
    || fail "isolated ACP child survived bridge SIGTERM cleanup"
  pass "ACP child runs in its own process group and remains bridge-owned for cleanup"
}

test_sighup_cleans_up_the_isolated_acp_child() {
  setup_case sighup-child-cleanup
  make_busy_writer "$CASE_ROOT"
  local fifo="$CASE_ROOT/stdin.fifo" pid child_pid tries=0
  mkfifo "$fifo"
  env FM_FAKE_ACP_SCENARIO=startup-hang FM_FAKE_ACP_LOG="$CASE_LOG" \
    FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    node "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      <"$fifo" >"$CASE_OUT" 2>"$CASE_ERR" &
  pid=$!
  ACTIVE_PIDS="$ACTIVE_PIDS $pid"
  exec 9>"$fifo"
  while [ "$tries" -lt 200 ]; do
    grep -q '"type":"spawn"' "$CASE_LOG" 2>/dev/null && break
    tries=$((tries + 1))
    sleep 0.02
  done
  [ "$tries" -lt 200 ] || fail "SIGHUP child cleanup case never spawned"
  child_pid=$(node -e '
    const fs=require("fs");
    const rows=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);
    process.stdout.write(String(rows.find((row)=>row.type==="spawn").pid));
  ' "$CASE_LOG")
  kill -HUP "$pid"
  exec 9>&-
  wait_bounded_exit "$pid" 200 || fail "SIGHUP cleanup exceeded bound"
  ACTIVE_PIDS=${ACTIVE_PIDS// $pid/}
  tries=0
  while [ "$tries" -lt 50 ] && kill -0 "$child_pid" 2>/dev/null; do
    tries=$((tries + 1))
    sleep 0.02
  done
  if kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL "$child_pid" 2>/dev/null || true
    fail "SIGHUP left the ACP child running"
  fi
  [ "$BOUNDED_RC" -eq 0 ] || fail "handled SIGHUP must exit cleanly, got $BOUNDED_RC"
  pass "SIGHUP performs bounded bridge-owned ACP child cleanup"
}

test_hung_busy_writer_is_killed_and_bounded_after_signal() {
  setup_case publishing-hung-writer
  make_busy_writer "$CASE_ROOT"
  local fifo="$CASE_ROOT/stdin.fifo" sync="$CASE_ROOT/busy-sync"
  local descendant_pid_file="$CASE_ROOT/busy-descendant.pid" descendant_pid pid tries=0
  mkdir -p "$sync"
  mkfifo "$fifo"
  env FM_FAKE_ACP_SCENARIO=happy FM_FAKE_ACP_LOG="$CASE_LOG" \
    FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" FM_FAKE_BUSY_BLOCK_DIR="$sync" \
    FM_FAKE_BUSY_IGNORE_TERM=1 FM_FAKE_BUSY_DESCENDANT_PID_FILE="$descendant_pid_file" \
    FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    node "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      <"$fifo" >"$CASE_OUT" 2>"$CASE_ERR" &
  pid=$!
  ACTIVE_PIDS="$ACTIVE_PIDS $pid"
  exec 9>"$fifo"
  while [ "$tries" -lt 200 ] && [ ! -e "$sync/entered" ]; do
    tries=$((tries + 1))
    sleep 0.02
  done
  [ -e "$sync/entered" ] || fail "hung busy writer never entered publishing-busy"
  kill -INT "$pid"
  exec 9>&-
  wait_bounded_exit "$pid" 400 \
    || fail "hung busy writer outlived the production timeout plus child cleanup bound"
  ACTIVE_PIDS=${ACTIVE_PIDS// $pid/}
  [ "$BOUNDED_RC" -eq 1 ] || fail "hung busy writer must exit 1, got $BOUNDED_RC"
  [ -s "$descendant_pid_file" ] || fail "hung busy writer did not record its descendant"
  descendant_pid=$(cat "$descendant_pid_file")
  tries=0
  while [ "$tries" -lt 50 ] && kill -0 "$descendant_pid" 2>/dev/null; do
    tries=$((tries + 1))
    sleep 0.02
  done
  if kill -0 "$descendant_pid" 2>/dev/null; then
    kill -KILL "$descendant_pid" 2>/dev/null || true
    fail "busy-event timeout left helper descendant $descendant_pid running"
  fi
  json_log_assert "$CASE_LOG" '
    assert(!rows.some((row) => row.type === "prompt"), "hung busy writer still sent session/prompt");
  '
  assert_grep "timed out" "$CASE_ERR" "hung busy writer timeout diagnostic changed"
  assert_grep "--event protocol-error" "$CASE_BUSY_LOG" "hung busy writer did not publish unknown"
  assert_safe_status_file "$CASE_STATE/task-3.status" 1
  assert_absent "$CASE_STATE/task-3.turn-ended" "hung busy writer fabricated a turn end"
  pass "hung busy writer and its descendants are TERM/KILL bounded without a test-side release"
}

test_sigterm_during_startup_is_bounded() {
  setup_case sigterm-startup
  make_busy_writer "$CASE_ROOT"
  local pid rc tries=0
  env FM_FAKE_ACP_SCENARIO=startup-hang FM_FAKE_ACP_LOG="$CASE_LOG" \
    FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    node "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      </dev/null >"$CASE_OUT" 2>"$CASE_ERR" &
  pid=$!
  ACTIVE_PIDS="$ACTIVE_PIDS $pid"
  while [ "$tries" -lt 200 ]; do
    if [ -f "$CASE_LOG" ] && grep -q '"method":"initialize"' "$CASE_LOG"; then
      break
    fi
    tries=$((tries + 1))
    sleep 0.02
  done
  [ "$tries" -lt 200 ] || fail "startup-hang scenario never received initialize"
  kill -TERM "$pid"
  tries=0
  while [ "$tries" -lt 150 ] && kill -0 "$pid" 2>/dev/null; do
    tries=$((tries + 1))
    sleep 0.02
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    ACTIVE_PIDS=${ACTIVE_PIDS// $pid/}
    fail "SIGTERM during startup did not finish within the bounded cleanup interval"
  fi
  set +e
  wait "$pid"
  rc=$?
  set -e
  ACTIVE_PIDS=${ACTIVE_PIDS// $pid/}
  [ "$rc" -eq 0 ] || fail "bounded startup SIGTERM must be a clean exit, got $rc"
  pass "SIGTERM during ACP startup terminates the child and exits within a fixed bound"
}

test_exit_and_stdin_close_are_bounded_without_cancelling() {
  local mode
  for mode in exit stdin-close; do
    setup_case "bounded-$mode"
    make_busy_writer "$CASE_ROOT"
    MODE="$mode" NODE_BIN="$NODE_BIN" BRIDGE="$BRIDGE" FAKE_AGENT="$FAKE_AGENT" \
      CASE_CWD="$CASE_CWD" CASE_STATE="$CASE_STATE" CASE_BRIEF="$CASE_BRIEF" \
      CASE_LOG="$CASE_LOG" CASE_BUSY_LOG="$CASE_BUSY_LOG" BUSY_WRITER="$BUSY_WRITER" \
      CASE_OUT="$CASE_OUT" CASE_ERR="$CASE_ERR" python3 <<'PY' \
      || fail "$mode did not cleanly bound an unresponsive active prompt: $(cat "$CASE_ERR")"
import os
import subprocess
import time

env = os.environ.copy()
env.update({
    "FM_FAKE_ACP_SCENARIO": "signal-cancel",
    "FM_FAKE_ACP_LOG": env["CASE_LOG"],
    "FM_FAKE_BUSY_LOG": env["CASE_BUSY_LOG"],
    "FM_CURSOR_BUSY_EVENT": env["BUSY_WRITER"],
})
argv = [
    env["NODE_BIN"], env["BRIDGE"],
    "--cwd", env["CASE_CWD"],
    "--task-id", "task-3",
    "--state-dir", env["CASE_STATE"],
    "--brief", env["CASE_BRIEF"],
    "--busy-gen", "gen-3",
    "--agent-bin", env["FAKE_AGENT"],
]
with open(env["CASE_OUT"], "wb") as stdout, open(env["CASE_ERR"], "wb") as stderr:
    process = subprocess.Popen(
        argv,
        stdin=subprocess.PIPE,
        stdout=stdout,
        stderr=stderr,
        env=env,
    )
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        try:
            log = open(env["CASE_LOG"], encoding="utf-8").read()
        except FileNotFoundError:
            log = ""
        if '"type":"signal-ready"' in log:
            break
        time.sleep(0.02)
    else:
        process.kill()
        process.wait()
        raise SystemExit("active prompt was never reached")
    if env["MODE"] == "exit":
        process.stdin.write(b"/exit\n")
        process.stdin.flush()
    else:
        process.stdin.close()
    try:
        code = process.wait(timeout=6)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise SystemExit("shutdown exceeded six seconds")
    if code != 0:
        raise SystemExit(f"bounded shutdown exited {code}")
PY
    assert_no_grep '"method":"session/cancel"' "$CASE_LOG" \
      "$mode must not masquerade as an interactive SIGINT cancellation"
  done
  pass "/exit and stdin close bound unresponsive prompts without sending session/cancel"
}

test_exit_waits_for_current_prompt_and_drops_queue() {
  setup_case exit
  set +e
  printf 'queued-before-exit\n/exit\nignored-after-exit\n' \
    | run_bridge happy >"$CASE_OUT" 2>"$CASE_ERR"
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "/exit scenario failed: $(cat "$CASE_ERR")"
  json_log_assert "$CASE_LOG" '
    const prompts = rows.filter((row) => row.type === "prompt");
    assert(prompts.length === 1, `/exit must drop queued prompts after the active turn, got ${prompts.length}`);
    assert(!rows.some((row) => row.type === "client-notification" && row.method === "session/cancel"), "/exit must not cancel the active prompt");
  '
  pass "graceful /exit waits for the active prompt, drops queued steer, and does not misreport child closure"
}

test_busy_writer_failure_is_fatal_without_forged_idle_or_turn_end() {
  setup_case busy-failure
  make_busy_writer "$CASE_ROOT"
  local rc
  set +e
  printf '/exit\n' | env \
    FM_FAKE_ACP_SCENARIO=happy FM_FAKE_ACP_LOG="$CASE_LOG" \
    FM_FAKE_BUSY_LOG="$CASE_BUSY_LOG" FM_FAKE_BUSY_FAIL_STATE=busy \
    FM_CURSOR_BUSY_EVENT="$BUSY_WRITER" \
    node "$BRIDGE" --cwd "$CASE_CWD" --task-id task-3 --state-dir "$CASE_STATE" \
      --brief "$CASE_BRIEF" --busy-gen gen-3 --agent-bin "$FAKE_AGENT" \
      >"$CASE_OUT" 2>"$CASE_ERR"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "busy writer refusal must be fatal"
  assert_no_grep " idle " "$CASE_BUSY_LOG" "busy writer failure forged idle state"
  assert_absent "$CASE_STATE/task-3.turn-ended" "busy writer failure forged a turn-end marker"
  json_log_assert "$CASE_LOG" '
    const requests = rows.filter((row) => row.type === "client-request");
    assert(!requests.some((row) => row.method === "session/prompt"), "prompt was sent after busy publication failed");
  '
  pass "busy-event failure stops before prompt submission and never fabricates idle or turn-end state"
}

test_repeated_termination_signals_do_not_extend_first_deadline
test_detached_acp_process_group_is_fully_reaped
test_status_append_rejects_post_preflight_fifo_and_symlink
test_spawn_error_and_close_only_are_bounded
test_cli_preflight_rejects_invalid_input_before_spawn
test_preflight_dependencies_and_failures_stop_before_agent
test_preflight_checks_state_write_and_brief_read_access
test_sidecar_session_id_is_bounded_and_control_free
test_new_session_protocol_rendering_and_atomic_state
test_busy_input_is_fifo_queued
test_load_resume_and_mismatch_refusal
test_load_failure_is_loud_and_never_falls_back_to_new
test_initialize_and_load_capability_are_explicit
test_authentication_is_advertised_and_returns_object
test_load_sidecar_id_remains_authoritative
test_load_replay_is_bound_to_saved_session_before_response
test_session_scoped_updates_and_permissions_match_current_session
test_permission_before_session_binding_is_rejected
test_permission_selection_uses_actual_server_options
test_permission_requests_require_acp_v1_tool_call_shape
test_cursor_extensions_escalate_and_blocking_ids_are_correlated
test_cursor_extensions_accept_official_optional_labels_and_nested_shapes
test_cursor_blocking_extensions_require_correlated_shapes
test_unknown_server_request_gets_method_not_found
test_jsonrpc_null_id_and_structured_params_details
test_status_appends_are_single_line_sanitized_and_bounded
test_protocol_failures_are_nonzero_and_publish_unknown
test_incoming_jsonrpc_envelopes_are_strict_v2
test_prompt_result_requires_exact_v1_stop_reason
test_cancel_requires_cancelled_stop_reason
test_sigint_cancels_prompt_and_permission_then_stays_reusable
test_termination_signal_upgrades_an_unanswered_sigint_cancel
test_signal_during_busy_publication_aborts_before_prompt
test_sigint_during_busy_publication_returns_to_reusable_idle
test_terminal_group_sigint_does_not_kill_busy_helper
test_sigint_during_idle_publication_is_a_reusable_noop
test_acp_child_has_an_isolated_process_group
test_sighup_cleans_up_the_isolated_acp_child
test_hung_busy_writer_is_killed_and_bounded_after_signal
test_sigterm_during_startup_is_bounded
test_exit_and_stdin_close_are_bounded_without_cancelling
test_exit_waits_for_current_prompt_and_drops_queue
test_busy_writer_failure_is_fatal_without_forged_idle_or_turn_end

echo "all fm-cursor-acp-bridge tests passed"
