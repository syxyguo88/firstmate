#!/usr/bin/env bash
# Hermetic/static contracts for the opt-in Cursor live gates. No Cursor agent,
# credential, network request, or model is used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRIMARY="$ROOT/tests/fm-cursor-primary-live-e2e.test.sh"
ACP="$ROOT/tests/fm-cursor-acp-live-e2e.test.sh"
CLI="$ROOT/tests/fm-cursor-acp-cli-contract-live-e2e.test.sh"
HELPERS="$ROOT/tests/cursor-live-helpers.sh"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-live-contract)

test_production_busy_record_path_and_live_consumer() {
  local state="$TMP_ROOT/busy-state" gen
  mkdir -p "$state"
  gen=$("$BUSY_EVENT" arm "$state" cursor-live) \
    || fail "production default busy arm failed"
  [ -n "$gen" ] || fail "production default busy arm returned no generation"
  assert_present "$state/cursor-live.busy-state" \
    "production busy writer did not create cursor-live.busy-state"
  assert_absent "$state/cursor-live.busy" \
    "legacy cursor-live.busy path unexpectedly exists"
  assert_grep 'BUSY_GEN=$("$BUSY_EVENT" arm "$STATE" cursor-live)' "$ACP" \
    "ACP live gate must use the production default arm contract"
  assert_grep 'busy_path = os.path.join(state, "cursor-live.busy-state")' "$ACP" \
    "ACP live gate drifted from the production busy-state record path"
  assert_no_grep 'cursor-live.busy")' "$ACP" \
    "ACP live gate still reads the nonexistent legacy busy path"
  pass "Cursor ACP live gate consumes the production default busy-state record"
}

test_primary_positive_startup_and_stop_evidence_contract() {
  assert_grep 'docs/supervision-protocols' "$PRIMARY" \
    "Primary fixture does not copy production supervision protocol docs"
  assert_grep 'session_start_completed' "$PRIMARY" \
    "Primary gate does not require a completed session-start tool event"
  for marker in \
    'SUPERVISION OPERATING INSTRUCTIONS - primary harness: cursor' \
    'CONTEXT' \
    'FLEET STATE'; do
    assert_grep "$marker" "$PRIMARY" \
      "Primary gate does not verify startup output marker $marker"
  done
  assert_grep 'cursor-live.meta' "$PRIMARY" \
    "Primary gate does not create a production-supported in-flight supervision need"
  assert_grep 'FIRSTMATE_OP: v1 turn-end-guard:' "$PRIMARY" \
    "Primary gate does not positively require the typed Stop follow-up"
  assert_grep 'followup_user_events' "$PRIMARY" \
    "Primary gate does not identify structured Stop follow-up user events"
  assert_grep 'disarm_supervision_need' "$PRIMARY" \
    "Primary controller does not remove its synthetic supervision need after follow-up"
  assert_grep 'os.unlink(supervision_meta)' "$PRIMARY" \
    "Primary controller does not atomically unlink its synthetic supervision meta"
  assert_grep 'terminal_text.strip() != sentinel' "$PRIMARY" \
    "Primary terminal result is not compared exactly to FINAL_SENTINEL"
  assert_grep 'def assistant_event_text(event):' "$PRIMARY" \
    "Primary gate does not extract official assistant message text blocks"
  assert_grep 'post_followup_assistant_events' "$PRIMARY" \
    "Primary gate does not bind final assistant evidence after the typed follow-up"
  assert_grep 'last_assistant_text.strip() != sentinel' "$PRIMARY" \
    "Primary post-follow-up assistant message is not compared exactly"
  assert_grep 'MAX_ASSISTANT_EVENTS=${FM_CURSOR_LIVE_MAX_ASSISTANT_EVENTS:-6}' "$PRIMARY" \
    "Primary default assistant-event budget is not six"
  assert_grep 'FM_CURSOR_LIVE_MAX_ASSISTANT_EVENTS is hard-capped at 6' "$PRIMARY" \
    "Primary assistant-event hard cap is not six"
  assert_grep 'bin/fm-wake-drain.sh' "$PRIMARY" \
    "Primary follow-up prompt does not require wake drain first"
  assert_grep 'fm_supervision_needed' "$PRIMARY" \
    "Primary follow-up prompt does not require a supervision-need recheck"
  assert_no_grep 'sentinel not in str(result.get("result", ""))' "$PRIMARY" \
    "Primary terminal result still accepts a sentinel substring"
  assert_grep 'pretool_deny_completed' "$PRIMARY" \
    "Primary gate does not bind deny evidence to the denied tool call completion"
  assert_no_grep 'zero stop follow-up turns' "$PRIMARY" \
    "Primary gate still treats absence of a Stop follow-up as proof"
  assert_grep 'assistant event count is the current official stream approximation' "$PRIMARY" \
    "Primary gate does not explain its model-round approximation"
  pass "Cursor Primary live gate requires completed startup digest and positive Stop evidence"
}

test_acp_sandbox_prompt_resume_and_workspace_contract() {
  assert_grep 'AGENT_WRAPPER="$LAB/agent-sandbox-wrapper"' "$ACP" \
    "ACP live gate does not use a LAB-local real-agent wrapper"
  assert_grep 'exec "$target" --sandbox enabled "$@"' "$ACP" \
    "ACP live agent wrapper does not force sandbox enabled"
  assert_grep 'tool_update_violation' "$ACP" \
    "ACP live gate does not fail on observed tool-like updates"
  assert_grep 'workspace_snapshot' "$ACP" \
    "ACP live gate does not snapshot its temporary workspace"
  assert_grep '("directory", mode)' "$ACP" \
    "ACP workspace snapshot does not record directories"
  assert_no_grep 'if name != ".git"' "$ACP" \
    "ACP workspace snapshot still excludes the whole .git tree"
  assert_grep 'workspace_changed' "$ACP" \
    "ACP live gate does not reject post-run workspace changes"
  assert_grep 'RESUME_SENTINEL=' "$ACP" \
    "ACP live gate does not use an independent resume sentinel"
  assert_grep 'atomic_replace_brief' "$ACP" \
    "ACP live gate does not atomically replace the brief before session/load"
  assert_grep 'agent_text_segment' "$ACP" \
    "ACP live gate does not extract marker-filtered agent text segments"
  assert_grep 'agent_text_responses' "$ACP" \
    "ACP live gate does not split complete known agent replies"
  assert_grep '== [launch_sentinel, resume_sentinel]' "$ACP" \
    "ACP resume does not require exactly one historical launch reply before the new reply"
  assert_no_grep 'while responses and responses[0] == launch' "$ACP" \
    "ACP resume still discards an unbounded number of launch replies"
  assert_grep 'first_prompt_offset = 0' "$ACP" \
    "ACP launch does not analyze output from the pre-prompt process boundary"
  assert_grep 'resume_prompt_offset = 0' "$ACP" \
    "ACP resume does not analyze replay from the start of its process output"
  assert_grep 'steer_prompt_offset = output_length(resumed_output)' "$ACP" \
    "ACP steer offset is not captured before writing stdin"
  assert_grep 'first_prompt_offset' "$ACP" \
    "ACP live gate does not bind launch output to its prompt-start offset"
  assert_grep 'resume_prompt_offset' "$ACP" \
    "ACP live gate does not bind resume output to its prompt-start offset"
  assert_grep 'steer_prompt_offset' "$ACP" \
    "ACP live gate does not bind steer output to its prompt-start offset"
  assert_grep 'steer_prompt_start_seq' "$ACP" \
    "ACP live gate does not observe the steer prompt-start boundary"
  assert_no_grep 'launch_sentinel in "".join(first_output)' "$ACP" \
    "ACP launch still accepts a sentinel substring"
  assert_no_grep 'resume_sentinel in "".join(resumed_output)' "$ACP" \
    "ACP resume still accepts a sentinel substring"
  assert_no_grep 'steer_sentinel in "".join(resumed_output)' "$ACP" \
    "ACP steer still accepts a sentinel substring"
  assert_grep 'def stop_process(process, term_grace=5, kill_grace=2):' "$ACP" \
    "ACP cleanup does not use an independent fixed grace"
  assert_no_grep 'process.wait(timeout=remaining(5))' "$ACP" \
    "ACP cleanup still consumes the shared protocol deadline"
  assert_grep 'fm_cursor_live_register_pid "$$"' "$ACP" \
    "ACP real-agent wrapper does not explicitly register its pre-exec PID"
  assert_grep 'unset FM_CURSOR_LIVE_LINEAGE_RECORD FM_CURSOR_LIVE_HELPERS' "$ACP" \
    "ACP real-agent wrapper exposes live cleanup registry state to Cursor"
  assert_grep 'fm_cursor_live_register_pid()' "$HELPERS" \
    "shared live helper does not provide fsynced explicit PID registration"
  assert_grep 'acpPromptRequestCount' "$ACP" \
    "ACP evidence does not name the auditable ACP prompt-request count"
  assert_no_grep 'modelPromptCount' "$ACP" \
    "ACP evidence still mislabels prompt requests as model prompts"
  assert_no_grep 'modelPromptLimit' "$ACP" \
    "ACP evidence still claims a lower-level model prompt limit"
  pass "Cursor ACP live gate forces sandbox and audits prompts, tools, resume, and workspace"
}

process_is_live() {
  local pid=$1 status
  kill -0 "$pid" 2>/dev/null || return 1
  status=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
  [ -n "$status" ] || return 1
  case "$status" in Z*|*Z*) return 1 ;; esac
  return 0
}

test_outer_timeout_reaps_nested_session_descendant() {
  local fake="$TMP_ROOT/fake-live-worker.sh"
  local child_pid_file="$TMP_ROOT/nested-child.pid"
  local out="$TMP_ROOT/timeout.out" err="$TMP_ROOT/timeout.err"
  local rc child_pid
  assert_present "$HELPERS" "shared Cursor live timeout helper is missing"
  # shellcheck source=tests/cursor-live-helpers.sh
  . "$HELPERS"
  cat >"$fake" <<'SH'
#!/usr/bin/env bash
python3 - "$FM_FAKE_NESTED_PID_FILE" <<'PY'
import os
import signal
import subprocess
import sys
import time

child = subprocess.Popen(
    [
        sys.executable,
        "-c",
        "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)",
    ],
    start_new_session=True,
)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(f"{child.pid}\n")
while True:
    time.sleep(1)
PY
SH
  chmod +x "$fake"
  set +e
  FM_FAKE_NESTED_PID_FILE="$child_pid_file" \
    fm_cursor_live_run_worker "$fake" 1 "fake nested Cursor live worker" \
      >"$out" 2>"$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fake nested timeout unexpectedly succeeded"
  assert_grep 'fake nested Cursor live worker exceeded 1s absolute timeout' "$err" \
    "outer timeout diagnostic changed"
  assert_present "$child_pid_file" "fake nested worker never recorded its detached child"
  child_pid=$(cat "$child_pid_file")
  if process_is_live "$child_pid"; then
    kill -KILL "$child_pid" 2>/dev/null || true
    fail "outer timeout left nested session child $child_pid alive"
  fi

  for script in "$PRIMARY" "$ACP" "$CLI"; do
    assert_grep 'cursor-live-helpers.sh' "$script" \
      "$(basename "$script") does not use the shared timeout owner"
    assert_no_grep 'start_new_session=True' "$script" \
      "$(basename "$script") starts an inner detached session"
    assert_no_grep 'os.killpg(process.pid' "$script" \
      "$(basename "$script") assumes an inner process is a process-group leader"
    assert_grep 'register_live_pid(process.pid)' "$script" \
      "$(basename "$script") does not explicitly register its inner process PID"
    assert_grep 'os.O_NOFOLLOW' "$script" \
      "$(basename "$script") PID registration follows symlinks"
    assert_grep 'stat.S_ISREG(os.fstat(fd).st_mode)' "$script" \
      "$(basename "$script") PID registration does not verify a regular file"
  done
  for script in "$PRIMARY" "$CLI"; do
    assert_grep 'env.pop("FM_CURSOR_LIVE_LINEAGE_RECORD", None)' "$script" \
      "$(basename "$script") exposes the trusted PID registry to the real Cursor process"
    assert_grep 'env.pop("FM_CURSOR_LIVE_HELPERS", None)' "$script" \
      "$(basename "$script") exposes live helper internals to the real Cursor process"
  done
  pass "Cursor live outer timeout reaps a captured nested session descendant"
}

run_detached_exit_case() {
  local name=$1 expected=$2
  local fake="$TMP_ROOT/$name-worker.sh"
  local child_pid_file="$TMP_ROOT/$name-child.pid"
  local out="$TMP_ROOT/$name.out" err="$TMP_ROOT/$name.err"
  local rc child_pid
  cat >"$fake" <<'SH'
#!/usr/bin/env bash
python3 - "$FM_FAKE_NESTED_PID_FILE" "$FM_FAKE_WORKER_EXIT" <<'PY'
import os
import signal
import subprocess
import sys
import time

child = subprocess.Popen(
    [
        sys.executable,
        "-c",
        "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)",
    ],
    start_new_session=True,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(f"{child.pid}\n")
    handle.flush()
    os.fsync(handle.fileno())
print(child.pid)
PY
child_pid=$(cat "$FM_FAKE_NESTED_PID_FILE")
# Exercise the same fsynced registration primitive used by the real ACP wrapper.
# shellcheck source=tests/cursor-live-helpers.sh
. "$FM_CURSOR_LIVE_HELPERS"
fm_cursor_live_register_pid "$child_pid"
exit "$FM_FAKE_WORKER_EXIT"
SH
  chmod +x "$fake"
  set +e
  FM_FAKE_NESTED_PID_FILE="$child_pid_file" \
  FM_FAKE_WORKER_EXIT="$expected" \
  FM_CURSOR_LIVE_HELPERS="$HELPERS" \
    fm_cursor_live_run_worker "$fake" 5 "fake $name Cursor live worker" \
      >"$out" 2>"$err"
  rc=$?
  set -e
  expect_code "$expected" "$rc" "helper must preserve the $name worker exit"
  assert_present "$child_pid_file" "$name worker never recorded its detached child"
  child_pid=$(cat "$child_pid_file")
  if process_is_live "$child_pid"; then
    kill -KILL "$child_pid" 2>/dev/null || true
    fail "helper left detached child $child_pid alive after $name worker exit"
  fi
}

test_outer_worker_exit_paths_reap_detached_descendants() {
  # shellcheck source=tests/cursor-live-helpers.sh
  . "$HELPERS"
  assert_grep 'def merge_registered_pids():' "$HELPERS" \
    "live helper does not merge append-only externally registered PIDs"
  assert_grep 'os.O_APPEND' "$HELPERS" \
    "live helper does not append PID records without replacement races"
  assert_no_grep 'os.replace(temporary, lineage_record)' "$HELPERS" \
    "live helper still overwrites the lineage record"
  run_detached_exit_case success 0
  run_detached_exit_case failure 1
  pass "Cursor live helper preserves success/failure while reaping detached descendants"
}

test_production_busy_record_path_and_live_consumer
test_primary_positive_startup_and_stop_evidence_contract
test_acp_sandbox_prompt_resume_and_workspace_contract
test_outer_worker_exit_paths_reap_detached_descendants
test_outer_timeout_reaps_nested_session_descendant

echo "all fm-cursor-live-contract tests passed"
