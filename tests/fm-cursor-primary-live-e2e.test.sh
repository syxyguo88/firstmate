#!/usr/bin/env bash
# Opt-in credentialed regression for native Cursor project hooks. The live run
# is isolated to a temporary repository and private Firstmate home. It permits
# only bounded local Shell calls and no network-write operation.
set -u

if [ "${FM_CURSOR_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CURSOR_LIVE_E2E=1 to run the isolated native Cursor primary hook regression"
  exit 0
fi

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

TIMEOUT=${FM_CURSOR_LIVE_TIMEOUT:-180}
case "$TIMEOUT" in
  ''|*[!0-9]*|0) fail "FM_CURSOR_LIVE_TIMEOUT must be a positive integer" ;;
esac
[ "$TIMEOUT" -le 600 ] || fail "FM_CURSOR_LIVE_TIMEOUT is capped at 600 seconds"
[ "$TIMEOUT" -ge 30 ] || fail "FM_CURSOR_LIVE_TIMEOUT must be at least 30 seconds"
MAX_ASSISTANT_EVENTS=${FM_CURSOR_LIVE_MAX_ASSISTANT_EVENTS:-6}
case "$MAX_ASSISTANT_EVENTS" in
  ''|*[!0-9]*|0) fail "FM_CURSOR_LIVE_MAX_ASSISTANT_EVENTS must be a positive integer" ;;
esac
[ "$MAX_ASSISTANT_EVENTS" -le 6 ] \
  || fail "FM_CURSOR_LIVE_MAX_ASSISTANT_EVENTS is hard-capped at 6"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"

# One outer process-group deadline prevents an Agent, hook, or descendant from
# surviving the test. The worker never writes user-level Cursor configuration.
# shellcheck source=tests/cursor-live-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/cursor-live-helpers.sh"
if [ "${FM_CURSOR_LIVE_WORKER:-0}" != 1 ]; then
  fm_cursor_live_run_worker "$0" "$TIMEOUT" "Cursor primary live E2E"
  exit $?
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v git >/dev/null 2>&1 || fail "git not found"
command -v jq >/dev/null 2>&1 || fail "jq not found (required by production Cursor hooks)"
command -v node >/dev/null 2>&1 || fail "node not found (required by production preTool policies)"
command -v agent >/dev/null 2>&1 || fail "real Cursor agent command not found"
AGENT_BIN=$(command -v agent)
case "$AGENT_BIN" in
  /*) ;;
  *) fail "Cursor agent path is not absolute: $AGENT_BIN" ;;
esac
AGENT_VERSION=$("$AGENT_BIN" --version 2>/dev/null) \
  || fail "Cursor agent --version failed"
"$AGENT_BIN" status --format json >/dev/null 2>&1 \
  || fail "Cursor agent is not logged in"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-cursor-primary-live.XXXXXX") \
  || fail "could not create isolated Cursor primary workspace"
chmod 700 "$LAB" || fail "could not make isolated workspace private"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
STATE="$HOME_DIR/state"
TRANSCRIPT="$LAB/cursor-primary.stream.jsonl"
STDERR_LOG="$LAB/cursor-primary.stderr"
mkdir -p "$PROJECT/bin" "$PROJECT/.cursor" "$PROJECT/.claude" \
  "$PROJECT/docs/supervision-protocols" \
  "$STATE" "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/projects" \
  || fail "could not create isolated Cursor primary fixture"
git -C "$PROJECT" init -q || fail "could not initialize isolated repository"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

# Use the current repository's production hook registrations and hook binaries.
# The minimal AGENTS.md intentionally omits any startup command, so the only
# source for the model's first session-start instruction is sessionStart output.
cp -R "$ROOT/bin/." "$PROJECT/bin/" \
  || fail "could not copy production Firstmate binaries"
cp "$ROOT/.cursor/hooks.json" "$PROJECT/.cursor/hooks.json" \
  || fail "could not copy production Cursor hooks"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json" \
  || fail "could not copy production Claude compatibility hooks"
cp -R "$ROOT/docs/supervision-protocols/." \
  "$PROJECT/docs/supervision-protocols/" \
  || fail "could not copy production supervision protocol docs"
printf '# Isolated Cursor native hook fixture\n' >"$PROJECT/AGENTS.md"

TOKEN="FM_CURSOR_PRIMARY_$$_${RANDOM}"
FINAL_SENTINEL="${TOKEN}_PASS"
DENY_TARGET="projects/${TOKEN}_DENIED"
PROMPT=$(cat <<EOF
This is a bounded local hook contract probe. Obey any injected session-start
context before these steps. If no such context exists, reply exactly
${TOKEN}_SESSION_CONTEXT_MISSING and stop.

After that injected instruction completes, use Shell exactly once to attempt:
cd ${DENY_TARGET}

That command must be denied by the project hook. Do not retry it. Do not use
any other tool. Do not access the network, push, create remote state, or modify
anything outside this temporary workspace and its supplied FM_HOME. Reply
exactly ${FINAL_SENTINEL}. If a typed turn-end supervision guard follows, first
use Shell to run bin/fm-wake-drain.sh. Then re-check locally by sourcing
bin/fm-supervision-lib.sh and calling fm_supervision_needed on \$FM_HOME/state.
If the synthetic need has already been removed, do not start a watcher. If a
real need remains, obey only the guard's local repair instructions inside this
temporary workspace/FM_HOME. Never access the network. Finally reply exactly
${FINAL_SENTINEL} again.
EOF
)

FM_CURSOR_REAL_AGENT="$AGENT_BIN" \
FM_CURSOR_REAL_PROJECT="$PROJECT" \
FM_CURSOR_REAL_HOME="$HOME_DIR" \
FM_CURSOR_REAL_STATE="$STATE" \
FM_CURSOR_REAL_TRANSCRIPT="$TRANSCRIPT" \
FM_CURSOR_REAL_STDERR="$STDERR_LOG" \
FM_CURSOR_REAL_PROMPT="$PROMPT" \
FM_CURSOR_REAL_SENTINEL="$FINAL_SENTINEL" \
FM_CURSOR_REAL_DENY_TARGET="$DENY_TARGET" \
FM_CURSOR_REAL_MODEL="${FM_CURSOR_LIVE_MODEL:-}" \
FM_CURSOR_REAL_MAX_ASSISTANT_EVENTS="$MAX_ASSISTANT_EVENTS" \
FM_CURSOR_REAL_TIMEOUT="$TIMEOUT" \
  python3 <<'PY' || fail "native Cursor primary hook contract failed"
import json
import os
import queue
import re
import stat
import subprocess
import threading
import time

agent = os.path.realpath(os.environ["FM_CURSOR_REAL_AGENT"])
project = os.path.realpath(os.environ["FM_CURSOR_REAL_PROJECT"])
home = os.path.realpath(os.environ["FM_CURSOR_REAL_HOME"])
state = os.path.realpath(os.environ["FM_CURSOR_REAL_STATE"])
transcript_path = os.environ["FM_CURSOR_REAL_TRANSCRIPT"]
stderr_path = os.environ["FM_CURSOR_REAL_STDERR"]
prompt = os.environ["FM_CURSOR_REAL_PROMPT"]
sentinel = os.environ["FM_CURSOR_REAL_SENTINEL"]
deny_target = os.environ["FM_CURSOR_REAL_DENY_TARGET"]
model = os.environ["FM_CURSOR_REAL_MODEL"]
max_assistant_events = int(os.environ["FM_CURSOR_REAL_MAX_ASSISTANT_EVENTS"])
total_timeout = int(os.environ["FM_CURSOR_REAL_TIMEOUT"])
supervision_meta = os.path.join(state, "cursor-live.meta")

args = [
    agent,
    "--trust",
    "--force",
    "--sandbox",
    "enabled",
    "--workspace",
    project,
    "--print",
    "--output-format",
    "stream-json",
]
if model:
    args.extend(["--model", model])
args.append(prompt)

env = os.environ.copy()
env.update(
    {
        "FM_ROOT_OVERRIDE": project,
        "FM_HOME": home,
        "FM_STATE_OVERRIDE": state,
        "FM_DATA_OVERRIDE": os.path.join(home, "data"),
        "FM_CONFIG_OVERRIDE": os.path.join(home, "config"),
        "FM_PROJECTS_OVERRIDE": os.path.join(home, "projects"),
    }
)
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
    args,
    cwd=project,
    env=env,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)
register_live_pid(process.pid)
stderr_chunks = []

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
events = []
tool_started = []
assistant_calls = 0
session_start_call_ids = set()
session_start_completed = []
pretool_deny_call_ids = set()
pretool_deny_completed = []
followup_prefix = "FIRSTMATE_OP: v1 turn-end-guard:"
followup_user_events = []
followup_event_positions = []
deadline = time.monotonic() + max(10, total_timeout - 10)

def completed_success(event):
    calls = event.get("tool_call")
    if not isinstance(calls, dict):
        return None
    for call in calls.values():
        if not isinstance(call, dict):
            continue
        result = call.get("result")
        if isinstance(result, dict) and "success" in result:
            return result["success"]
    return None

def assistant_event_text(event):
    message = event.get("message")
    if not isinstance(message, dict):
        return None
    content = message.get("content")
    if not isinstance(content, list):
        return None
    texts = []
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "text":
            continue
        text = block.get("text")
        if not isinstance(text, str):
            raise RuntimeError("assistant text block contained a non-string text field")
        texts.append(text)
    return "".join(texts)

def arm_supervision_need():
    tmp_path = f"{supervision_meta}.tmp-{os.getpid()}"
    body = "\n".join(
        [
            "kind=crew",
            "harness=cursor",
            f"home={home}",
            f"project={project}",
            "window=fm-cursor-live-stop-proof",
            "",
        ]
    )
    with open(tmp_path, "x", encoding="utf-8") as handle:
        handle.write(body)
    os.replace(tmp_path, supervision_meta)

def disarm_supervision_need():
    try:
        os.unlink(supervision_meta)
    except FileNotFoundError as error:
        raise RuntimeError(
            "typed Stop follow-up arrived after synthetic supervision meta disappeared"
        ) from error

try:
    with open(transcript_path, "w", encoding="utf-8") as transcript:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("native Cursor stream exceeded its inner deadline")
            try:
                line = stdout_queue.get(timeout=min(remaining, 0.25))
            except queue.Empty:
                if process.poll() is not None:
                    break
                continue
            if line is None:
                break
            transcript.write(line)
            transcript.flush()
            try:
                event = json.loads(line)
            except json.JSONDecodeError as error:
                raise RuntimeError("Cursor stream-json emitted invalid JSON") from error
            if not isinstance(event, dict) or not isinstance(event.get("type"), str):
                raise RuntimeError("Cursor stream-json emitted an invalid event object")
            events.append(event)
            if (
                event.get("type") == "user"
                and followup_prefix
                in json.dumps(event, ensure_ascii=False, sort_keys=True)
            ):
                followup_user_events.append(event)
                followup_event_positions.append(len(events) - 1)
                if len(followup_user_events) > 1:
                    process.terminate()
                    raise RuntimeError(
                        "production Stop emitted duplicate typed turn-end follow-ups"
                    )
                # The live controller owns this synthetic test state. Atomic
                # unlink immediately removes the need before Cursor's next
                # Stop, preventing the fixture itself from creating a loop.
                disarm_supervision_need()
            if event.get("type") == "assistant":
                assistant_calls += 1
                if assistant_calls > max_assistant_events:
                    process.terminate()
                    raise RuntimeError(
                        f"Cursor exceeded the hard {max_assistant_events}-assistant-event boundary"
                    )
            if event.get("type") == "tool_call" and event.get("subtype") == "started":
                tool_started.append(event)
                started_text = json.dumps(event, sort_keys=True)
                if "bin/fm-session-start.sh" in started_text:
                    session_start_call_ids.add(event.get("call_id"))
                if f"cd {deny_target}" in started_text:
                    pretool_deny_call_ids.add(event.get("call_id"))
            if (
                event.get("type") == "tool_call"
                and event.get("subtype") == "completed"
                and event.get("call_id") in session_start_call_ids
            ):
                success = completed_success(event)
                if success is None:
                    raise RuntimeError(
                        "session-start completed tool event did not expose an official success result"
                    )
                success_text = json.dumps(success, ensure_ascii=False, sort_keys=True)
                startup_markers = (
                    "SUPERVISION OPERATING INSTRUCTIONS - primary harness: cursor",
                    "CONTEXT",
                    "FLEET STATE",
                )
                missing = [marker for marker in startup_markers if marker not in success_text]
                if missing:
                    raise RuntimeError(
                        f"session-start success result omitted startup markers: {missing!r}"
                    )
                session_start_completed.append(event)
                arm_supervision_need()
            if (
                event.get("type") == "tool_call"
                and event.get("subtype") == "completed"
                and event.get("call_id") in pretool_deny_call_ids
            ):
                pretool_deny_completed.append(event)
    return_code = process.wait(timeout=3)
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
    stderr_thread.join(timeout=1)
    stdout_thread.join(timeout=1)
    with open(stderr_path, "w", encoding="utf-8") as stderr_file:
        stderr_file.write("".join(stderr_chunks))

if return_code != 0:
    raise RuntimeError(f"Cursor agent exited {return_code}; diagnostics retained only in private temp state")

init_events = [
    event
    for event in events
    if event.get("type") == "system" and event.get("subtype") == "init"
]
if len(init_events) != 1:
    raise RuntimeError(f"expected one Cursor init event, got {len(init_events)}")
if os.path.realpath(init_events[0].get("cwd", "")) != project:
    raise RuntimeError("Cursor init event did not bind to the isolated workspace")
if not isinstance(init_events[0].get("session_id"), str) or not init_events[0]["session_id"]:
    raise RuntimeError("Cursor init event omitted session identity")

result_events = [event for event in events if event.get("type") == "result"]
if len(result_events) != 1:
    raise RuntimeError(f"expected one terminal Cursor result, got {len(result_events)}")
result = result_events[0]
terminal_text = result.get("result")
if (
    result.get("subtype") != "success"
    or result.get("is_error") is not False
    or not isinstance(terminal_text, str)
    or terminal_text.strip() != sentinel
):
    raise RuntimeError("Cursor terminal result was not exactly the unique success sentinel")

if len(followup_user_events) != 1:
    raise RuntimeError(
        f"expected exactly one typed production Stop follow-up, got {len(followup_user_events)}"
    )
result_position = next(
    index for index, event in enumerate(events) if event is result
)
if followup_event_positions[0] >= result_position:
    raise RuntimeError("terminal result arrived before the typed Stop follow-up")
if os.path.exists(supervision_meta):
    raise RuntimeError("synthetic supervision meta remained after the typed Stop follow-up")
post_followup_assistant_events = [
    (index, event)
    for index, event in enumerate(events)
    if index > followup_event_positions[0] and event.get("type") == "assistant"
]
if not post_followup_assistant_events:
    raise RuntimeError("typed Stop follow-up had no subsequent assistant message")
last_assistant_position, last_assistant_event = post_followup_assistant_events[-1]
last_assistant_text = assistant_event_text(last_assistant_event)
if last_assistant_text is None or last_assistant_text.strip() != sentinel:
    raise RuntimeError(
        "last assistant message after the typed Stop follow-up was not exactly the sentinel"
    )
if last_assistant_position >= result_position:
    raise RuntimeError("post-follow-up assistant message was not followed by terminal result")
# The assistant event count is the current official stream approximation for
# model rounds. Tool calls are deliberately counted separately and are not
# represented as model calls.
if assistant_calls == 0 or assistant_calls > max_assistant_events:
    raise RuntimeError(
        f"structured assistant-event count is {assistant_calls}, cap is {max_assistant_events}"
    )

started_json = [json.dumps(event, sort_keys=True) for event in tool_started]
session_start_calls = [
    row for row in started_json if "bin/fm-session-start.sh" in row
]
if len(session_start_calls) != 1 or len(session_start_completed) != 1:
    raise RuntimeError(
        "sessionStart additional_context did not produce exactly one successful completed session-start tool call"
    )
if not any(f"cd {deny_target}" in row for row in started_json):
    raise RuntimeError("the safe persistent-cd probe was not observed as a structured tool call")

if len(pretool_deny_completed) != 1:
    raise RuntimeError(
        f"expected one completed persistent-cd denial, got {len(pretool_deny_completed)}"
    )
pretool_deny_json = json.dumps(pretool_deny_completed[0], sort_keys=True)
if "[persistent-cd]" not in pretool_deny_json or "deny" not in pretool_deny_json.lower():
    raise RuntimeError("production Cursor preToolUse did not return the persistent-cd deny evidence")

for row in started_json:
    if re.search(r"\b(git\s+push|gh\s+pr\s+create|curl|wget|scp|ssh)\b", row, re.I):
        raise RuntimeError("live probe attempted a forbidden network-write-capable command")

if not os.path.isfile(os.path.join(state, ".lock")):
    raise RuntimeError("session-start command did not establish isolated primary session state")
if os.path.exists(os.path.join(project, deny_target)):
    raise RuntimeError("persistent-cd probe unexpectedly created or entered its denied target")
PY

printf 'ok - Cursor %s native hooks completed the cursor startup digest, denied persistent-cd, emitted one typed Stop repair follow-up, and completed within %s assistant events\n' \
  "$AGENT_VERSION" "$MAX_ASSISTANT_EVENTS"
