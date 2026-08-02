#!/usr/bin/env bash
# Shared absolute-timeout owner for opt-in Cursor live tests. The worker is the
# only new session created by the test harness. On timeout, this owner records
# all recursive descendants (including other PGIDs), terminates the worker
# group, kills captured survivors, and verifies that none remain live.

fm_cursor_live_register_pid() {
  local pid=$1 record=${FM_CURSOR_LIVE_LINEAGE_RECORD:-}
  case "$pid" in
    ''|*[!0-9]*|0|1) return 1 ;;
  esac
  [ -n "$record" ] || return 0
  FM_CURSOR_LIVE_REGISTER_PID=$pid \
  FM_CURSOR_LIVE_REGISTER_RECORD=$record \
    python3 <<'PY'
import os
import stat

pid = os.environ["FM_CURSOR_LIVE_REGISTER_PID"]
record = os.environ["FM_CURSOR_LIVE_REGISTER_RECORD"]
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
PY
}

fm_cursor_live_run_worker() {
  local script=$1 timeout=$2 label=$3
  FM_CURSOR_LIVE_SCRIPT=$script \
  FM_CURSOR_LIVE_TIMEOUT_SECONDS=$timeout \
  FM_CURSOR_LIVE_TIMEOUT_LABEL=$label \
    python3 <<'PY'
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time

script = os.path.abspath(os.environ["FM_CURSOR_LIVE_SCRIPT"])
timeout = int(os.environ["FM_CURSOR_LIVE_TIMEOUT_SECONDS"])
label = os.environ["FM_CURSOR_LIVE_TIMEOUT_LABEL"]
env = os.environ.copy()
env["FM_CURSOR_LIVE_WORKER"] = "1"
lineage_fd, lineage_record = tempfile.mkstemp(
    prefix="fm-cursor-live-lineage.",
    dir=os.environ.get("TMPDIR") or None,
)
os.close(lineage_fd)
os.chmod(lineage_record, 0o600)
env["FM_CURSOR_LIVE_LINEAGE_RECORD"] = lineage_record

process = subprocess.Popen(
    ["bash", script],
    env=env,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    start_new_session=True,
)
stdout_chunks = []
stderr_chunks = []

def drain(stream, chunks):
    for chunk in iter(lambda: stream.read(4096), ""):
        chunks.append(chunk)

stdout_thread = threading.Thread(
    target=drain, args=(process.stdout, stdout_chunks), daemon=True
)
stderr_thread = threading.Thread(
    target=drain, args=(process.stderr, stderr_chunks), daemon=True
)
stdout_thread.start()
stderr_thread.start()

def process_table():
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,pgid=,stat="],
        text=True,
        stderr=subprocess.DEVNULL,
    )
    table = {}
    for line in output.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4:
            continue
        try:
            pid, ppid, pgid = map(int, fields[:3])
        except ValueError:
            continue
        table[pid] = (ppid, pgid, fields[3])
    return table

def append_registered_pid(pid):
    payload = f"{pid}\n".encode("ascii")
    fd = os.open(lineage_record, os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, payload)
        os.fsync(fd)
    finally:
        os.close(fd)

captured = {process.pid}
known_pgids = {process.pid: process.pid}
append_registered_pid(process.pid)

def merge_registered_pids():
    try:
        lines = open(lineage_record, encoding="ascii").read().splitlines()
    except FileNotFoundError:
        return
    for line in lines:
        if not line.isdigit():
            continue
        pid = int(line)
        if pid > 1:
            captured.add(pid)

def record_lineage():
    # Merge append-only worker/inner registrations before following current
    # PPID edges. A PID remains owned after reparenting, and helper scans never
    # replace externally appended records.
    merge_registered_pids()
    table = process_table()
    before = set(captured)
    children = {}
    for pid, (ppid, _, _) in table.items():
        children.setdefault(ppid, []).append(pid)
    pending = list(captured)
    while pending:
        parent = pending.pop()
        for child in children.get(parent, ()):
            if child not in captured:
                captured.add(child)
                pending.append(child)
    for pid in captured:
        if pid in table:
            known_pgids[pid] = table[pid][1]
    for pid in sorted(captured - before):
        append_registered_pid(pid)
    return table

def live_captured(table):
    return {
        pid
        for pid in captured
        if pid in table and "Z" not in table[pid][2]
    }

def signal_captured(sig, table):
    own_pgid = os.getpgrp()
    live = live_captured(table)
    groups = {
        known_pgids[pid]
        for pid in live
        if known_pgids.get(pid, 0) > 1 and known_pgids[pid] != own_pgid
    }
    for pgid in sorted(groups):
        try:
            os.killpg(pgid, sig)
        except ProcessLookupError:
            pass
    for pid in sorted(live):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass

def wait_for_captured_exit(seconds):
    end = time.monotonic() + seconds
    table = record_lineage()
    while live_captured(table) and time.monotonic() < end:
        time.sleep(0.01)
        table = record_lineage()
    return table

# Poll the live lineage instead of blocking in communicate(). This records a
# detached child before an early-exiting worker can orphan and reparent it.
deadline = time.monotonic() + timeout
table = record_lineage()
while process.poll() is None and time.monotonic() < deadline:
    time.sleep(0.05)
    table = record_lineage()

timed_out = process.poll() is None
worker_returncode = process.poll()
table = record_lineage()
worker_pgid = known_pgids.get(process.pid, process.pid)

# Success, early failure, and timeout use the same ordering. TERM the worker
# PGID first even if its leader is gone; this catches unrecorded same-group
# children and lets a registered bridge run production detached-child cleanup.
try:
    os.killpg(worker_pgid, signal.SIGTERM)
except ProcessLookupError:
    pass
table = wait_for_captured_exit(1)

# Registered/captured detached groups are the second cleanup layer.
if live_captured(table):
    signal_captured(signal.SIGTERM, table)
    table = wait_for_captured_exit(1)

if live_captured(table):
    signal_captured(signal.SIGKILL, table)
table = wait_for_captured_exit(2)
remaining = live_captured(table)

if process.poll() is None:
    process.kill()
try:
    process.wait(timeout=2)
except subprocess.TimeoutExpired:
    pass

stdout_thread.join(timeout=1)
stderr_thread.join(timeout=1)
try:
    os.unlink(lineage_record)
except FileNotFoundError:
    pass

if timed_out:
    # Timeout paths intentionally suppress worker stdout/stderr because live
    # tools may include private diagnostics. Only bounded process metadata is
    # reported.
    sys.stderr.write(f"not ok - {label} exceeded {timeout}s absolute timeout\n")
else:
    sys.stdout.write("".join(stdout_chunks))
    sys.stderr.write("".join(stderr_chunks))

if remaining:
    sys.stderr.write(
        "not ok - live worker cleanup left captured descendant pid(s): "
        + ",".join(str(pid) for pid in sorted(remaining))
        + "\n"
    )
    raise SystemExit(1)
if timed_out:
    raise SystemExit(1)
raise SystemExit(worker_returncode)
PY
}
