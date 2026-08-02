#!/usr/bin/env bash
# Opt-in credentialed live regression for the production Cursor ACP bridge.
# Exactly three auditable ACP session/prompt requests are permitted:
# new-session launch, resumed-session launch, and one resumed-session steer.
# This is not a claim about Cursor's lower-level model-round count.
set -u

if [ "${FM_CURSOR_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CURSOR_LIVE_E2E=1 to run the isolated real Cursor ACP bridge regression"
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
ACP_PROMPT_REQUEST_LIMIT=3
command -v python3 >/dev/null 2>&1 || fail "python3 not found"

# shellcheck source=tests/cursor-live-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/cursor-live-helpers.sh"
if [ "${FM_CURSOR_LIVE_WORKER:-0}" != 1 ]; then
  fm_cursor_live_run_worker "$0" "$TIMEOUT" "Cursor ACP bridge live E2E"
  exit $?
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$ROOT/bin/fm-cursor-acp-bridge.mjs"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"
command -v node >/dev/null 2>&1 || fail "node not found"
command -v git >/dev/null 2>&1 || fail "git not found"
command -v agent >/dev/null 2>&1 || fail "real Cursor agent command not found"
[ -x "$BRIDGE" ] || fail "production Cursor ACP bridge is missing or not executable"
[ -x "$BUSY_EVENT" ] || fail "production busy-event writer is missing or not executable"
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

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-cursor-acp-live.XXXXXX") \
  || fail "could not create isolated Cursor ACP bridge fixture"
chmod 700 "$LAB" || fail "could not make isolated fixture private"
WORKSPACE="$LAB/workspace"
STATE="$LAB/state"
BRIEF="$LAB/brief.md"
EVIDENCE="$LAB/evidence.json"
mkdir -p "$WORKSPACE" "$STATE" || fail "could not create ACP fixture directories"
git -C "$WORKSPACE" init -q || fail "could not initialize isolated ACP repository"
AGENT_WRAPPER="$LAB/agent-sandbox-wrapper"
cat >"$AGENT_WRAPPER" <<'SH'
#!/usr/bin/env bash
set -eu
: "${FM_CURSOR_REAL_AGENT_TARGET:?missing real Cursor agent target}"
: "${FM_CURSOR_LIVE_HELPERS:?missing Cursor live helpers}"
# Register the wrapper PID before exec replaces it with the detached ACP server.
# This closes the reparenting window if the bridge exits immediately after spawn.
. "$FM_CURSOR_LIVE_HELPERS"
fm_cursor_live_register_pid "$$"
target=$FM_CURSOR_REAL_AGENT_TARGET
unset FM_CURSOR_LIVE_LINEAGE_RECORD FM_CURSOR_LIVE_HELPERS
unset FM_CURSOR_REAL_AGENT_TARGET
exec "$target" --sandbox enabled "$@"
SH
chmod 700 "$AGENT_WRAPPER" || fail "could not make the sandbox agent wrapper private"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

TOKEN="FM_CURSOR_ACP_$$_${RANDOM}"
LAUNCH_SENTINEL="${TOKEN}_LAUNCH"
RESUME_SENTINEL="${TOKEN}_RESUME"
STEER_SENTINEL="${TOKEN}_STEER"
cat >"$BRIEF" <<EOF
This is an isolated Cursor ACP live contract probe. Do not use tools, access the
network, or modify files. Reply exactly ${LAUNCH_SENTINEL}.
EOF

BUSY_GEN=$("$BUSY_EVENT" arm "$STATE" cursor-live) \
  || fail "could not arm the real busy-state generation"

FM_CURSOR_REAL_AGENT="$AGENT_WRAPPER" \
FM_CURSOR_REAL_AGENT_TARGET="$AGENT_BIN" \
FM_CURSOR_REAL_BRIDGE="$BRIDGE" \
FM_CURSOR_REAL_BUSY_EVENT="$BUSY_EVENT" \
FM_CURSOR_REAL_CWD="$WORKSPACE" \
FM_CURSOR_REAL_STATE="$STATE" \
FM_CURSOR_REAL_BRIEF="$BRIEF" \
FM_CURSOR_REAL_BUSY_GEN="$BUSY_GEN" \
FM_CURSOR_REAL_LAUNCH_SENTINEL="$LAUNCH_SENTINEL" \
FM_CURSOR_REAL_RESUME_SENTINEL="$RESUME_SENTINEL" \
FM_CURSOR_REAL_STEER_SENTINEL="$STEER_SENTINEL" \
FM_CURSOR_REAL_MODEL="${FM_CURSOR_LIVE_MODEL:-}" \
FM_CURSOR_REAL_TIMEOUT="$TIMEOUT" \
FM_CURSOR_REAL_EVIDENCE="$EVIDENCE" \
FM_CURSOR_REAL_PROMPT_LIMIT="$ACP_PROMPT_REQUEST_LIMIT" \
FM_CURSOR_LIVE_HELPERS="$ROOT/tests/cursor-live-helpers.sh" \
  python3 <<'PY' || fail "real production Cursor ACP bridge contract failed"
import json
import hashlib
import os
import re
import stat
import subprocess
import threading
import time

agent_wrapper = os.path.realpath(os.environ["FM_CURSOR_REAL_AGENT"])
bridge = os.path.realpath(os.environ["FM_CURSOR_REAL_BRIDGE"])
busy_event = os.path.realpath(os.environ["FM_CURSOR_REAL_BUSY_EVENT"])
cwd = os.path.realpath(os.environ["FM_CURSOR_REAL_CWD"])
state = os.path.realpath(os.environ["FM_CURSOR_REAL_STATE"])
brief = os.path.realpath(os.environ["FM_CURSOR_REAL_BRIEF"])
busy_gen = os.environ["FM_CURSOR_REAL_BUSY_GEN"]
launch_sentinel = os.environ["FM_CURSOR_REAL_LAUNCH_SENTINEL"]
resume_sentinel = os.environ["FM_CURSOR_REAL_RESUME_SENTINEL"]
steer_sentinel = os.environ["FM_CURSOR_REAL_STEER_SENTINEL"]
model = os.environ["FM_CURSOR_REAL_MODEL"]
evidence_path = os.environ["FM_CURSOR_REAL_EVIDENCE"]
prompt_limit = int(os.environ["FM_CURSOR_REAL_PROMPT_LIMIT"])
total_timeout = int(os.environ["FM_CURSOR_REAL_TIMEOUT"])
deadline = time.monotonic() + max(10, total_timeout - 10)
sidecar_path = os.path.join(state, "cursor-live.cursor-session.json")
turn_ended_path = os.path.join(state, "cursor-live.turn-ended")
busy_path = os.path.join(state, "cursor-live.busy-state")
all_processes = []

def workspace_snapshot():
    # No paths are excluded. Cursor is given an initialized temporary
    # repository, so .git and every other path must settle back to the exact
    # baseline by the end of the live gate.
    snapshot = {}
    def describe(path):
        metadata = os.lstat(path)
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISLNK(metadata.st_mode):
            return ("symlink", mode, os.readlink(path))
        if stat.S_ISDIR(metadata.st_mode):
            return ("directory", mode)
        if stat.S_ISREG(metadata.st_mode):
            digest = hashlib.sha256()
            with open(path, "rb") as handle:
                for chunk in iter(lambda: handle.read(65536), b""):
                    digest.update(chunk)
            return ("file", mode, metadata.st_size, digest.hexdigest())
        return ("other", mode)

    snapshot["."] = describe(cwd)
    for root, dirs, files in os.walk(cwd, topdown=True, followlinks=False):
        dirs[:] = sorted(dirs)
        for name in sorted(dirs + files):
            path = os.path.join(root, name)
            relative = os.path.relpath(path, cwd)
            snapshot[relative] = describe(path)
    return snapshot

initial_workspace_snapshot = workspace_snapshot()

def remaining(cap):
    value = deadline - time.monotonic()
    if value <= 0:
        raise RuntimeError("Cursor ACP live inner deadline expired")
    return min(cap, value)

def read_busy():
    try:
        raw = open(busy_path, encoding="utf-8").read().strip()
    except FileNotFoundError:
        return None
    match = re.fullmatch(
        r"v1 gen=([^ ]+) seq=([0-9]+) state=([^ ]+) "
        r"source=([^ ]+) event=([^ ]+) ts=([0-9]+)",
        raw,
    )
    if not match:
        raise RuntimeError(f"invalid production busy record: {raw!r}")
    return {
        "gen": match.group(1),
        "seq": int(match.group(2)),
        "state": match.group(3),
        "source": match.group(4),
        "event": match.group(5),
    }

def stop_process(process, term_grace=5, kill_grace=2):
    if process.poll() is not None:
        return process.wait()
    process.terminate()
    try:
        return process.wait(timeout=term_grace)
    except subprocess.TimeoutExpired:
        process.kill()
        return process.wait(timeout=kill_grace)

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

MARKER_LINE = re.compile(r"^\[(?:update|cursor|acp):[^\]\r\n]+\]$")

def output_length(chunks):
    return sum(len(chunk) for chunk in chunks)

def agent_text_segment(chunks, offset):
    raw = "".join(chunks)[offset:]
    agent_lines = [
        line
        for line in raw.splitlines()
        if not MARKER_LINE.fullmatch(line.strip())
    ]
    return "\n".join(agent_lines).strip()

def agent_text_responses(chunks, offset, known_sentinels):
    remaining = agent_text_segment(chunks, offset)
    responses = []
    known = tuple(sorted(set(known_sentinels), key=len, reverse=True))
    while remaining:
        matched = None
        for candidate in known:
            if not remaining.startswith(candidate):
                continue
            suffix = remaining[len(candidate):]
            if (
                not suffix
                or suffix[0].isspace()
                or any(suffix.startswith(other) for other in known)
            ):
                matched = candidate
                break
        if matched is None:
            responses.append(remaining)
            break
        responses.append(matched)
        remaining = remaining[len(matched):].lstrip()
    return responses

def atomic_replace_brief(sentinel):
    temporary = f"{brief}.tmp-{os.getpid()}"
    text = (
        "This is an isolated Cursor ACP live contract probe. Do not use tools, "
        "access the network, or modify files. "
        f"Reply exactly {sentinel}.\n"
    )
    with open(temporary, "x", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(temporary, brief)

def raise_on_tool_update(process, tool_update_violation, details):
    if not tool_update_violation.is_set():
        return
    if process.poll() is None:
        process.terminate()
    marker = details[0] if details else "unknown tool update"
    raise RuntimeError(f"Cursor ACP live gate observed forbidden tool update {marker}")

def wait_for(predicate, process, tool_update_violation, details, description):
    while time.monotonic() < deadline:
        raise_on_tool_update(process, tool_update_violation, details)
        if predicate():
            return
        if process.poll() is not None:
            raise RuntimeError(
                f"Cursor ACP bridge exited {process.returncode} before {description}"
            )
        time.sleep(0.05)
    raise RuntimeError(f"timed out waiting for {description}")

def wait_for_prompt_start(
    process,
    sequence_floor,
    tool_update_violation,
    details,
    description,
):
    while time.monotonic() < deadline:
        raise_on_tool_update(process, tool_update_violation, details)
        record = read_busy()
        if (
            record is not None
            and record["gen"] == busy_gen
            and record["seq"] > sequence_floor
            and record["state"] == "busy"
            and record["source"] == "cursor-acp"
            and record["event"] == "prompt-start"
        ):
            return record["seq"]
        if process.poll() is not None:
            raise RuntimeError(
                f"Cursor ACP bridge exited {process.returncode} before {description}"
            )
        time.sleep(0.01)
    raise RuntimeError(f"timed out waiting for {description}")

def start_bridge(label):
    args = [
        process_node,
        bridge,
        "--cwd",
        cwd,
        "--task-id",
        "cursor-live",
        "--state-dir",
        state,
        "--brief",
        brief,
        "--busy-gen",
        busy_gen,
        "--agent-bin",
        agent_wrapper,
        "--role",
        "crew",
    ]
    if model:
        args.extend(["--model", model])
    out_path = os.path.join(state, f"{label}.stdout")
    err_path = os.path.join(state, f"{label}.stderr")
    process = subprocess.Popen(
        args,
        cwd=cwd,
        env={**os.environ, "FM_CURSOR_BUSY_EVENT": busy_event},
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    register_live_pid(process.pid)
    all_processes.append(process)
    output = []
    errors = []
    tool_update_violation = threading.Event()
    tool_update_details = []

    def drain(stream, chunks, path, watch_tool_updates):
        scan_tail = ""
        with open(path, "w", encoding="utf-8") as handle:
            for chunk in iter(lambda: stream.read(4096), ""):
                chunks.append(chunk)
                handle.write(chunk)
                handle.flush()
                if watch_tool_updates:
                    scan_tail = (scan_tail + chunk)[-8192:]
                    match = re.search(
                        r"\[(?:update:tool[^]]*|cursor:(?:task|update_todos|generate_image))\]",
                        scan_tail,
                    )
                    if match and not tool_update_violation.is_set():
                        tool_update_details.append(match.group(0))
                        tool_update_violation.set()
                        if process.poll() is None:
                            process.terminate()

    out_thread = threading.Thread(
        target=drain,
        args=(process.stdout, output, out_path, True),
        daemon=True,
    )
    err_thread = threading.Thread(
        target=drain,
        args=(process.stderr, errors, err_path, False),
        daemon=True,
    )
    out_thread.start()
    err_thread.start()
    return (
        process,
        output,
        errors,
        out_thread,
        err_thread,
        tool_update_violation,
        tool_update_details,
    )

def finish_bridge(
    process,
    out_thread,
    err_thread,
    tool_update_violation,
    tool_update_details,
):
    raise_on_tool_update(process, tool_update_violation, tool_update_details)
    process.stdin.write("/exit\n")
    process.stdin.flush()
    try:
        code = process.wait(timeout=remaining(8))
    except subprocess.TimeoutExpired:
        code = stop_process(process)
    out_thread.join(timeout=1)
    err_thread.join(timeout=1)
    raise_on_tool_update(process, tool_update_violation, tool_update_details)
    if code != 0:
        raise RuntimeError(f"Cursor ACP bridge did not exit cleanly (exit {code})")

process_node = os.environ.get("NODE") or subprocess.check_output(
    ["sh", "-c", "command -v node"], text=True
).strip()
initial_busy_record = read_busy()
if initial_busy_record is None or initial_busy_record["gen"] != busy_gen:
    raise RuntimeError("production default busy arm did not seed the live record")
acp_prompt_request_count = 0
try:
    (
        first,
        first_output,
        _,
        first_out_thread,
        first_err_thread,
        first_tool_update_violation,
        first_tool_update_details,
    ) = start_bridge("new")
    acp_prompt_request_count += 1
    first_prompt_offset = 0
    first_prompt_start_seq = wait_for_prompt_start(
        first,
        initial_busy_record["seq"],
        first_tool_update_violation,
        first_tool_update_details,
        "new-session prompt-start boundary",
    )

    def first_complete():
        record = read_busy()
        return (
            agent_text_responses(
                first_output, first_prompt_offset, (launch_sentinel,)
            ) == [launch_sentinel]
            and os.path.isfile(sidecar_path)
            and os.path.isfile(turn_ended_path)
            and record is not None
            and record["gen"] == busy_gen
            and record["seq"] > first_prompt_start_seq
            and record["state"] == "idle"
            and record["source"] == "cursor-acp"
            and record["event"] == "prompt-stop"
        )

    wait_for(
        first_complete,
        first,
        first_tool_update_violation,
        first_tool_update_details,
        "new-session sentinel and busy-to-idle transition",
    )
    first_record = read_busy()
    first_seq = first_record["seq"]
    finish_bridge(
        first,
        first_out_thread,
        first_err_thread,
        first_tool_update_violation,
        first_tool_update_details,
    )

    sidecar_mode = stat.S_IMODE(os.lstat(sidecar_path).st_mode)
    if sidecar_mode != 0o600:
        raise RuntimeError(f"Cursor ACP sidecar mode is {sidecar_mode:o}, expected 600")
    if os.path.islink(sidecar_path):
        raise RuntimeError("Cursor ACP sidecar is unexpectedly a symlink")
    sidecar = json.load(open(sidecar_path, encoding="utf-8"))
    if (
        sidecar.get("version") != 1
        or sidecar.get("cwd") != cwd
        or sidecar.get("role") != "crew"
        or not isinstance(sidecar.get("sessionId"), str)
        or not sidecar["sessionId"]
    ):
        raise RuntimeError("Cursor ACP sidecar v1 fields are invalid")
    original_session_id = sidecar["sessionId"]
    atomic_replace_brief(resume_sentinel)

    try:
        os.unlink(turn_ended_path)
    except FileNotFoundError:
        pass
    (
        resumed,
        resumed_output,
        _,
        resumed_out_thread,
        resumed_err_thread,
        resumed_tool_update_violation,
        resumed_tool_update_details,
    ) = start_bridge("resume")
    acp_prompt_request_count += 1
    resume_prompt_offset = 0
    resume_prompt_start_seq = wait_for_prompt_start(
        resumed,
        first_seq,
        resumed_tool_update_violation,
        resumed_tool_update_details,
        "session/load prompt-start boundary",
    )

    def resume_launch_complete():
        record = read_busy()
        return (
            agent_text_responses(
                resumed_output,
                resume_prompt_offset,
                (launch_sentinel, resume_sentinel),
            ) == [launch_sentinel, resume_sentinel]
            and os.path.isfile(turn_ended_path)
            and record is not None
            and record["seq"] > resume_prompt_start_seq
            and record["state"] == "idle"
            and record["event"] == "prompt-stop"
        )

    wait_for(
        resume_launch_complete,
        resumed,
        resumed_tool_update_violation,
        resumed_tool_update_details,
        "session/load independent resume prompt completion",
    )
    resume_seq = read_busy()["seq"]
    os.unlink(turn_ended_path)
    steer = (
        f"Do not use tools or access the network. Reply exactly {steer_sentinel}."
    )
    steer_prompt_offset = output_length(resumed_output)
    resumed.stdin.write(steer + "\n")
    resumed.stdin.flush()
    acp_prompt_request_count += 1
    if acp_prompt_request_count > prompt_limit:
        raise RuntimeError(
            "live ACP prompt-request cap exceeded: "
            f"{acp_prompt_request_count}>{prompt_limit}"
        )
    steer_prompt_start_seq = wait_for_prompt_start(
        resumed,
        resume_seq,
        resumed_tool_update_violation,
        resumed_tool_update_details,
        "resumed-session steer prompt-start boundary",
    )

    def steer_complete():
        record = read_busy()
        return (
            agent_text_responses(
                resumed_output, steer_prompt_offset, (steer_sentinel,)
            ) == [steer_sentinel]
            and os.path.isfile(turn_ended_path)
            and record is not None
            and record["seq"] > steer_prompt_start_seq
            and record["state"] == "idle"
            and record["event"] == "prompt-stop"
        )

    wait_for(
        steer_complete,
        resumed,
        resumed_tool_update_violation,
        resumed_tool_update_details,
        "resumed-session steer and busy-to-idle transition",
    )
    steer_seq = read_busy()["seq"]
    finish_bridge(
        resumed,
        resumed_out_thread,
        resumed_err_thread,
        resumed_tool_update_violation,
        resumed_tool_update_details,
    )
    loaded_sidecar = json.load(open(sidecar_path, encoding="utf-8"))
    if loaded_sidecar.get("sessionId") != original_session_id:
        raise RuntimeError("session/load replaced the authoritative sidecar sessionId")
    if acp_prompt_request_count != prompt_limit:
        raise RuntimeError(
            "live ACP prompt-request count changed: "
            f"{acp_prompt_request_count}, expected {prompt_limit}"
        )
    final_workspace_snapshot = workspace_snapshot()
    workspace_changed = final_workspace_snapshot != initial_workspace_snapshot
    if workspace_changed:
        changed_paths = sorted(
            set(initial_workspace_snapshot) ^ set(final_workspace_snapshot)
            | {
                path
                for path in set(initial_workspace_snapshot)
                & set(final_workspace_snapshot)
                if initial_workspace_snapshot[path] != final_workspace_snapshot[path]
            }
        )
        raise RuntimeError(
            f"Cursor ACP live gate changed temporary workspace files: {changed_paths!r}"
        )
    with open(evidence_path, "w", encoding="utf-8") as evidence_file:
        json.dump(
            {
                "contract": "cursor-acp-live-v1",
                "sidecarVersion": loaded_sidecar["version"],
                "sidecarPrivate": sidecar_mode == 0o600,
                "role": loaded_sidecar["role"],
                "newEvidence": {
                    "launchSentinel": True,
                    "busyIdleSequence": first_seq,
                },
                "resumeEvidence": {
                    "resumeSentinel": True,
                    "busyIdleSequence": resume_seq,
                },
                "steerEvidence": {
                    "steerSentinel": True,
                    "busyIdleSequence": steer_seq,
                },
                "turnEnded": os.path.isfile(turn_ended_path),
                "workspaceChanged": workspace_changed,
                "observedToolUpdates": False,
                "acpPromptRequestCount": acp_prompt_request_count,
                "acpPromptRequestLimit": prompt_limit,
            },
            evidence_file,
            sort_keys=True,
        )
        evidence_file.write("\n")
finally:
    for process in reversed(all_processes):
        if process.poll() is None:
            stop_process(process)
PY

python3 - "$EVIDENCE" <<'PY' || fail "Cursor ACP live evidence JSON is incomplete"
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert doc["contract"] == "cursor-acp-live-v1", doc
assert doc["sidecarVersion"] == 1 and doc["sidecarPrivate"] is True, doc
assert doc["role"] == "crew", doc
assert doc["newEvidence"]["launchSentinel"] is True, doc
assert doc["resumeEvidence"]["resumeSentinel"] is True, doc
assert doc["steerEvidence"]["steerSentinel"] is True, doc
assert doc["turnEnded"] is True, doc
assert doc["workspaceChanged"] is False, doc
assert doc["observedToolUpdates"] is False, doc
assert doc["acpPromptRequestCount"] == doc["acpPromptRequestLimit"] == 3, doc
sequences = [
    doc["newEvidence"]["busyIdleSequence"],
    doc["resumeEvidence"]["busyIdleSequence"],
    doc["steerEvidence"]["busyIdleSequence"],
]
assert sequences == sorted(sequences), doc
assert len(set(sequences)) == 3, doc
PY

printf 'limitation: permission, cancellation, and malformed ACP envelopes remain owned by deterministic fake-ACP coverage; sandbox mode plus rejection of observed tool updates does not prove that Cursor made no network access\n'
printf 'ok - Cursor %s production ACP bridge covered real initialize/auth/new/prompt, private v1 sidecar, busy-idle/turn-ended, session/load, and one steer within %s auditable ACP prompt requests\n' \
  "$AGENT_VERSION" "$ACP_PROMPT_REQUEST_LIMIT"
