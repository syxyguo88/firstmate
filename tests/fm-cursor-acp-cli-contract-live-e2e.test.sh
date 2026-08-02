#!/usr/bin/env bash
# Opt-in, no-model smoke against the installed Cursor ACP server. This stops
# after initialize/authenticate/session/new and must never send session/prompt.
set -u

if [ "${FM_CURSOR_CLI_CONTRACT_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CURSOR_CLI_CONTRACT_E2E=1 to run the no-model real Cursor ACP CLI contract"
  exit 0
fi

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

TIMEOUT=${FM_CURSOR_CLI_CONTRACT_TIMEOUT:-30}
case "$TIMEOUT" in
  ''|*[!0-9]*|0) fail "FM_CURSOR_CLI_CONTRACT_TIMEOUT must be a positive integer" ;;
esac
[ "$TIMEOUT" -le 300 ] || fail "FM_CURSOR_CLI_CONTRACT_TIMEOUT is capped at 300 seconds"
[ "$TIMEOUT" -ge 10 ] || fail "FM_CURSOR_CLI_CONTRACT_TIMEOUT must be at least 10 seconds"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"

# Re-exec the live body in its own process group so one absolute deadline owns
# startup, login checks, protocol exchange, and descendant cleanup.
# shellcheck source=tests/cursor-live-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/cursor-live-helpers.sh"
if [ "${FM_CURSOR_LIVE_WORKER:-0}" != 1 ]; then
  fm_cursor_live_run_worker "$0" "$TIMEOUT" "no-model Cursor ACP CLI contract"
  exit $?
fi

command -v git >/dev/null 2>&1 || fail "git not found"
command -v agent >/dev/null 2>&1 || fail "real Cursor agent command not found"
AGENT_BIN=$(command -v agent)
case "$AGENT_BIN" in
  /*) ;;
  *) fail "Cursor agent path is not absolute: $AGENT_BIN" ;;
esac
AGENT_VERSION=$("$AGENT_BIN" --version 2>/dev/null) \
  || fail "Cursor agent --version failed"
"$AGENT_BIN" acp --help >/dev/null 2>&1 \
  || fail "installed Cursor agent does not expose the ACP command"
"$AGENT_BIN" status --format json >/dev/null 2>&1 \
  || fail "Cursor agent is not logged in"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-cursor-acp-cli-contract.XXXXXX") \
  || fail "could not create isolated Cursor ACP CLI workspace"
chmod 700 "$LAB" || fail "could not make isolated workspace private"
WORKSPACE="$LAB/workspace"
mkdir -p "$WORKSPACE" || fail "could not create temporary workspace"
git -C "$WORKSPACE" init -q || fail "could not initialize temporary repository"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

FM_CURSOR_REAL_AGENT="$AGENT_BIN" FM_CURSOR_REAL_CWD="$WORKSPACE" \
FM_CURSOR_REAL_TIMEOUT="$TIMEOUT" \
  python3 <<'PY' || fail "real Cursor ACP initialize/authenticate/session/new contract failed"
import json
import os
import queue
import stat
import subprocess
import threading
import time

agent = os.path.realpath(os.environ["FM_CURSOR_REAL_AGENT"])
cwd = os.path.realpath(os.environ["FM_CURSOR_REAL_CWD"])
total_timeout = int(os.environ["FM_CURSOR_REAL_TIMEOUT"])
stderr_chunks = []
env = os.environ.copy()
env.pop("FM_CURSOR_LIVE_LINEAGE_RECORD", None)
env.pop("FM_CURSOR_LIVE_HELPERS", None)

def register_live_pid(pid):
    record = os.environ.get("FM_CURSOR_LIVE_LINEAGE_RECORD")
    if not record:
        return
    flags = os.O_WRONLY | os.O_APPEND
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(record, flags)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise RuntimeError("Cursor live lineage record is not a regular file")
        os.write(fd, f"{pid}\n".encode("ascii"))
        os.fsync(fd)
    finally:
        os.close(fd)

process = subprocess.Popen(
    [agent, "--trust", "--force", "acp"],
    cwd=cwd,
    env=env,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)
register_live_pid(process.pid)

def drain_stderr():
    for chunk in iter(lambda: process.stderr.read(4096), ""):
        stderr_chunks.append(chunk)

stderr_thread = threading.Thread(target=drain_stderr, daemon=True)
stderr_thread.start()
stdout_queue = queue.Queue()

def drain_stdout():
    for line in process.stdout:
        stdout_queue.put(line)
    stdout_queue.put(None)

stdout_thread = threading.Thread(target=drain_stdout, daemon=True)
stdout_thread.start()
deadline = time.monotonic() + max(5, total_timeout - 5)
next_id = 1
sent_methods = []

def valid_id(value):
    return (
        value is None
        or isinstance(value, str)
        or (isinstance(value, (int, float)) and not isinstance(value, bool))
    )

def validate_message(message):
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        raise RuntimeError("ACP emitted a non-JSON-RPC-v2 object")
    if "params" in message and not isinstance(message["params"], dict):
        raise RuntimeError("ACP emitted non-object JSON-RPC params")
    if "method" in message:
        if not isinstance(message["method"], str) or not message["method"]:
            raise RuntimeError("ACP emitted an invalid method")
        if "result" in message or "error" in message:
            raise RuntimeError("ACP request mixed method with result/error")
        if "id" in message and not valid_id(message["id"]):
            raise RuntimeError("ACP request used an invalid id")
        return "request" if "id" in message else "notification"
    if "id" not in message or not valid_id(message["id"]):
        raise RuntimeError("ACP response omitted a valid id")
    if ("result" in message) == ("error" in message):
        raise RuntimeError("ACP response must contain exactly one of result/error")
    if "error" in message:
        error = message["error"]
        if (
            not isinstance(error, dict)
            or not isinstance(error.get("code"), int)
            or isinstance(error.get("code"), bool)
            or not isinstance(error.get("message"), str)
        ):
            raise RuntimeError("ACP emitted an invalid error object")
    return "response"

def read_message():
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("ACP response deadline expired")
        if process.poll() is not None:
            raise RuntimeError("ACP process exited before completing the no-model contract")
        try:
            line = stdout_queue.get(timeout=min(remaining, 0.25))
        except queue.Empty:
            continue
        if line is None:
            raise RuntimeError("ACP stdout closed before completing the no-model contract")
        try:
            message = json.loads(line)
        except json.JSONDecodeError as error:
            raise RuntimeError("ACP emitted invalid JSON") from error
        return message, validate_message(message)

def request(method, params):
    global next_id
    request_id = next_id
    next_id += 1
    sent_methods.append(method)
    envelope = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
    process.stdin.write(json.dumps(envelope, separators=(",", ":")) + "\n")
    process.stdin.flush()
    while True:
        message, kind = read_message()
        if kind == "request":
            raise RuntimeError(
                f"unexpected ACP server request before any model prompt: {message['method']}"
            )
        if kind == "notification":
            continue
        if message["id"] != request_id:
            raise RuntimeError("ACP response id did not match the outstanding request")
        if "error" in message:
            raise RuntimeError(f"ACP {method} returned an error")
        return message["result"]

try:
    initialized = request(
        "initialize",
        {
            "protocolVersion": 1,
            "clientCapabilities": {
                "fs": {"readTextFile": False, "writeTextFile": False},
                "terminal": False,
            },
            "clientInfo": {"name": "firstmate-cli-contract-smoke", "version": "1"},
        },
    )
    if not isinstance(initialized, dict) or initialized.get("protocolVersion") != 1:
        raise RuntimeError("ACP did not negotiate protocolVersion=1")
    auth_methods = initialized.get("authMethods")
    if not isinstance(auth_methods, list) or not any(
        isinstance(method, dict) and method.get("id") == "cursor_login"
        for method in auth_methods
    ):
        raise RuntimeError("ACP did not advertise cursor_login")
    capabilities = initialized.get("agentCapabilities")
    if not isinstance(capabilities, dict) or capabilities.get("loadSession") is not True:
        raise RuntimeError("ACP did not advertise loadSession=true")

    authenticated = request("authenticate", {"methodId": "cursor_login"})
    if not isinstance(authenticated, dict):
        raise RuntimeError("ACP authenticate returned a non-object result")

    created = request("session/new", {"cwd": cwd, "mcpServers": []})
    session_id = created.get("sessionId") if isinstance(created, dict) else None
    if (
        not isinstance(session_id, str)
        or not session_id
        or len(session_id) > 512
        or any(ord(char) < 32 or ord(char) == 127 for char in session_id)
    ):
        raise RuntimeError("ACP session/new returned an invalid sessionId")
    if sent_methods != ["initialize", "authenticate", "session/new"]:
        raise RuntimeError(f"unexpected no-model request sequence: {sent_methods!r}")
finally:
    if process.stdin and not process.stdin.closed:
        process.stdin.close()
    try:
        return_code = process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            return_code = process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            return_code = process.wait(timeout=2)
    stderr_thread.join(timeout=1)
    stdout_thread.join(timeout=1)

if return_code != 0:
    raise RuntimeError(f"ACP server did not exit cleanly after stdin close (exit {return_code})")
PY

printf 'ok - Cursor %s real ACP CLI negotiated v1 cursor_login/loadSession and created a session without session/prompt\n' \
  "$AGENT_VERSION"
