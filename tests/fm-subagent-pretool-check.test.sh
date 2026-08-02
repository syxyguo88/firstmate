#!/usr/bin/env bash
# Behavior tests for the primary-session delegation-shape guard: the tracked
# hook registration, shared settings boundary, and PreToolUse classifier.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-subagent-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-subagent-pretool-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

BRIEF_ONLY_ROUTE='first classify the work under the AGENTS.md intake contract, then use bin/fm-brief.sh followed by bin/fm-spawn.sh for dispatched work'
SCOUT_ROUTE='first classify the work under the AGENTS.md intake contract: work already classified as a scout goes to bin/fm-scout.sh "<question>" [project], while authorized ship work and its bounded research go to bin/fm-brief.sh then bin/fm-spawn.sh'

# Every delegation, scheduling, worktree, and task-tracking tool Claude Code
# 2.1.217 offered a primary session in the observed baseline.
# This inventory is shape-classification coverage for the shipped guard and the
# recommended local Claude deny-list hardening list, but tracked settings must
# not ship that Claude-only permissions layer.
DELEGATION_TOOLS='Task Agent Workflow RemoteTrigger Monitor ScheduleWakeup SendMessage EnterWorktree ExitWorktree CronCreate CronDelete CronList TaskCreate TaskGet TaskList TaskUpdate TaskStop TaskOutput'

# Tools that must stay available: denying these would break ordinary work.
PRESERVED_TOOLS='Bash Edit Read Write Skill ToolSearch WebFetch WebSearch NotebookEdit ReportFindings DesignSync PushNotification'

# Session-local todo-list tools. They match a delegation stem but create no
# runnable work, so the guard's plan-only exclusion must allow them.
PLAN_ONLY_TOOLS='TaskCreate TaskUpdate'

# Names the plan-only exclusion must NOT release. Five of them contain a
# plan-only name as a substring and would be let through by a substring rather
# than exact-name match; bare Task is what a shortened entry of "task" would
# release. Together they make the exact-name contract testable instead of
# assumed.
PLAN_ONLY_NEAR_MISSES='TaskCreateAgent TaskCreateWorktree TaskUpdateAgent RemoteTaskCreate Task TaskCreator'

run_tool() {
  local tool=$1 rc=0
  shift
  : > "$OUT"
  : > "$ERR"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$@" \
    "$CHECK" --claude --tool "$tool" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {
  local label=$1 tool=$2 rc=0
  shift 2
  run_tool "$tool" "$@" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label ($tool) must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label ($tool) allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label ($tool) allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
  local label=$1 tool=$2 rc=0
  run_tool "$tool" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label ($tool) must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label ($tool) deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny omitted Claude's permission decision: $(cat "$ERR")"
  jq -e --arg tool "$tool" '.systemMessage | startswith("[subagent-dispatch]") and contains("blocked tool: " + $tool)' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny message lost its code or tool name: $(jq -r '.systemMessage' "$ERR")"
}

# ---------------------------------------------------------------------------
# Delegation-shape PreToolUse guard.
# ---------------------------------------------------------------------------

test_guard_denies_every_currently_known_delegation_tool() {
  local tool
  for tool in $DELEGATION_TOOLS; do
    case "$tool" in
      TaskOutput|TaskStop|TaskGet|TaskList|CronList) continue ;;
      TaskCreate|TaskUpdate) continue ;;
    esac
    expect_deny "known delegation tool" "$tool"
  done
  pass "the guard independently denies every work-creating delegation tool by shape"
}

test_guard_denies_hypothetical_future_tools() {
  # A fixed deny list is fail-open against tools that do not exist yet.
  # None of these names is on any list.
  local tool
  for tool in SubagentCreate SpawnWorker DelegateTask AgentPool WorkflowRun \
              ScheduleJob CronSchedule CreateWorktree DispatchAgent TaskHandoff \
              RemoteExec BackgroundAgent; do
    expect_deny "future delegation tool" "$tool"
  done
  pass "the guard denies delegation-shaped tools that no deny list knows about yet"
}

test_guard_allows_ordinary_and_observe_only_tools() {
  local tool
  for tool in $PRESERVED_TOOLS; do
    expect_allow "ordinary tool" "$tool"
  done
  # Observing or stopping work that already exists is not creating unaccounted
  # work, and blocking it would strand a runaway task with no way to end it.
  for tool in TaskOutput TaskStop TaskGet TaskList CronList BashOutput KillShell; do
    expect_allow "observe-or-stop tool" "$tool"
  done
  pass "the guard leaves ordinary tools and observe-or-stop operations alone"
}

test_guard_allows_session_local_todo_tools() {
  # These write, so they are not observe-or-stop, but what they write is the
  # harness's session-local todo list: no executor, no agent, no worktree, no
  # schedule, nothing that outlives the session. Denying them stops the primary
  # tracking its own plan and grants no delegation power in exchange.
  local tool
  for tool in $PLAN_ONLY_TOOLS; do
    expect_allow "session-local todo tool" "$tool"
  done
  pass "the guard leaves the session-local todo list alone"
}

test_plan_only_exclusion_is_exact_name() {
  # The plan-only exclusion must never widen by substring or by a shorter stem.
  # Every name here would be released by such a widening and must stay denied.
  local tool
  for tool in $PLAN_ONLY_NEAR_MISSES; do
    expect_deny "plan-only near miss" "$tool"
  done
  pass "the plan-only exclusion releases exactly two names and nothing that merely contains them"
}

test_guard_never_classifies_mcp_tools() {
  # An MCP server names its own tools; a task or agent noun there is common and
  # has nothing to do with fleet dispatch.
  local tool
  for tool in mcp__linear__list_issues mcp__tracker__create_task \
              mcp__acme__spawn_agent mcp__slack__slack_send_message; do
    expect_allow "MCP tool" "$tool"
  done
  pass "MCP tool names are never classified as harness delegation"
}

test_cursor_native_mcp_namespace_is_exempt_only_with_prefix() {
  local payload out rc
  payload='{"hook_event_name":"preToolUse","cursor_version":"2.1.0","tool_name":"MCP:tracker_create_task","tool_input":{"title":"ship"}}'
  rc=0
  out=$(printf '%s' "$payload" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --cursor 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "Cursor native MCP tool must allow with exit 0, got $rc"
  [ -z "$out" ] || fail "Cursor native MCP tool allow must be silent: $out"

  payload='{"hook_event_name":"preToolUse","cursor_version":"2.1.0","tool_name":"tracker_create_task","tool_input":{"title":"ship"}}'
  rc=0
  out=$(printf '%s' "$payload" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --cursor 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "ordinary delegation-shaped Cursor tool deny must use native exit 0, got $rc"
  printf '%s' "$out" | jq -e '.permission == "deny" and (.agent_message | contains("blocked tool: tracker_create_task"))' >/dev/null 2>&1 \
    || fail "ordinary tracker_create_task must not inherit the MCP namespace exemption: $out"
  pass "Cursor native MCP: namespace is exempt without releasing ordinary delegation-shaped names"
}

test_deny_message_defers_to_intake_classification() {
  local actual
  printf '#!/usr/bin/env bash\n' > "$PRIMARY/bin/fm-scout.sh"
  run_tool Agent && fail "scout-present case must still deny"
  actual=$(jq -r '.systemMessage' "$ERR")
  case "$actual" in
    *"$SCOUT_ROUTE"*) ;;
    *) fail "deny must reserve bin/fm-scout.sh for classified scout work: $actual" ;;
  esac
  case "$actual" in
    *'investigation or diagnosis goes to bin/fm-scout.sh'*) fail "deny must not classify all investigation or diagnosis as scout work: $actual" ;;
  esac
  rm -f "$PRIMARY/bin/fm-scout.sh"
  run_tool Agent && fail "scout-absent case must still deny"
  actual=$(jq -r '.systemMessage' "$ERR")
  case "$actual" in
    *"$BRIEF_ONLY_ROUTE"*) ;;
    *) fail "deny must degrade to brief-then-spawn when fm-scout.sh is absent: $actual" ;;
  esac
  pass "deny defers to intake classification and degrades gracefully without fm-scout.sh"
}

test_escape_hatch_allows_deliberate_use() {
  local rc value
  expect_allow "escape hatch set" Agent FM_ALLOW_SUBAGENT=1
  expect_deny "escape hatch unset" Agent
  for value in '' 0 yes true 11; do
    rc=0
    run_tool Agent "FM_ALLOW_SUBAGENT=$value" || rc=$?
    [ "$rc" -eq 2 ] || fail "FM_ALLOW_SUBAGENT='$value' must not release the guard, got exit $rc"
  done
  pass "the single documented escape hatch releases the guard only on the exact opt-in value"
}

test_task_worktree_and_non_firstmate_repo_are_inert() {
  local child="$TMP_ROOT/child" plain="$TMP_ROOT/plain" rc=0
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  printf '# fixture\n' > "$child/AGENTS.md"
  : > "$OUT"
  : > "$ERR"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a crewmate task worktree must be out of scope, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "task-worktree no-op wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "task-worktree no-op wrote stderr: $(cat "$ERR")"
  rc=0
  printf '%s' '{"hook_event_name":"preToolUse","cursor_version":"2.1.0","tool_name":"Agent","tool_input":{}}' \
    | FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
      "$CHECK" --cursor > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "Cursor guard must be inert in a crewmate task worktree"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] \
    || fail "Cursor guard produced output in a crewmate task worktree"

  mkdir -p "$plain/bin"
  git -C "$plain" init -q
  rc=0
  FM_ROOT_OVERRIDE="$plain" FM_HOME="$plain" FM_STATE_OVERRIDE="$plain/state" \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a non-firstmate repo must be out of scope, got exit $rc"
  pass "the guard is inert in a crewmate task worktree and in a non-firstmate repo"
}

test_secondmate_home_is_in_scope() {
  local second="$TMP_ROOT/second" rc=0
  git -C "$PRIMARY" worktree add -q -b fixture-second "$second"
  mkdir -p "$second/bin" "$second/state"
  printf '# fixture\n' > "$second/AGENTS.md"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  FM_ROOT_OVERRIDE="$second" FM_HOME="$second" FM_STATE_OVERRIDE="$second/state" \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a marked secondmate home operates a fleet and must be guarded, got exit $rc"
  rc=0
  printf '%s' '{"hook_event_name":"preToolUse","cursor_version":"2.1.0","tool_name":"Agent","tool_input":{}}' \
    | FM_ROOT_OVERRIDE="$second" FM_HOME="$second" FM_STATE_OVERRIDE="$second/state" \
      "$CHECK" --cursor > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "Cursor secondmate deny must use native exit 0"
  jq -e '.permission == "deny"' "$OUT" >/dev/null 2>&1 \
    || fail "Cursor guard did not activate in a marked linked secondmate home: $(cat "$OUT")"
  pass "a marked secondmate home is guarded for Claude and Cursor even though it is a linked worktree"
}

test_stdin_transports_and_output_shapes() {
  local rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Agent","tool_input":{"prompt":"go"}}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Claude-shaped stdin must deny, got exit $rc"
  [ ! -s "$OUT" ] || fail "Claude deny wrote stdout, which makes Claude ignore the deny: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"toolName":"Agent"}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Grok-shaped stdin must deny, got exit $rc"
  jq -e '.decision == "deny" and (.reason | startswith("[subagent-dispatch]"))' "$OUT" >/dev/null 2>&1 \
    || fail "default deny mode must write a Grok decision object on stdout: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "Bash through stdin must allow, got exit $rc"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "stdin allow wrote output"
  pass "both stdin transports classify correctly and Claude's deny keeps stdout empty"
}

test_cursor_native_deny_allow_and_duplicate_suppression() {
  local payload out rc=0
  payload='{"hook_event_name":"preToolUse","cursor_version":"2.1.0","tool_name":"Agent","tool_input":{"prompt":"go"}}'
  out=$(printf '%s' "$payload" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --cursor 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "Cursor delegation deny must return native JSON with exit 0, got $rc"
  printf '%s' "$out" | jq -e '
    (keys | sort) == ["agent_message", "permission", "user_message"]
    and .permission == "deny"
    and (.user_message | startswith("[subagent-dispatch]"))
    and (.agent_message | startswith("[subagent-dispatch]"))
    and (.agent_message | contains("blocked tool: Agent"))
  ' >/dev/null 2>&1 || fail "Cursor delegation deny must be flat native JSON with the existing reason: $out"

  rc=0
  payload='{"hook_event_name":"preToolUse","cursor_version":"2.1.0","tool_name":"Read","tool_input":{"path":"README.md"}}'
  out=$(printf '%s' "$payload" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --cursor 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "Cursor ordinary tool must allow with exit 0, got $rc"
  [ -z "$out" ] || fail "Cursor ordinary tool allow must be silent: $out"

  rc=0
  payload='{"hook_event_name":"preToolUse","cursor_version":"2.1.0","tool_name":"Agent","tool_input":{"prompt":"go"}}'
  out=$(printf '%s' "$payload" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "--claude must suppress native Cursor delegation duplicate, got $rc"
  [ -z "$out" ] || fail "--claude native Cursor delegation duplicate must be silent: $out"

  for payload in \
    '{"cursor_version":"2.1.0","tool_name":"Agent","tool_input":{"prompt":"go"}}' \
    '{"hook_event_name":"damaged","cursor_version":"2.1.0","tool_name":"Agent","tool_input":{"prompt":"go"}}'
  do
    rc=0
    out=$(printf '%s' "$payload" \
      | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
        "$CHECK" --claude 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "--claude must suppress partial Cursor delegation payload, got $rc"
    [ -z "$out" ] || fail "--claude partial Cursor delegation payload must be silent: $out"
  done

  rc=0
  out=$(printf '%s' '{"tool_name":"Agent","tool_input":{"prompt":"go"}}' \
    | CURSOR_AGENT=1 FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "CURSOR_AGENT alone must not suppress ordinary Claude delegation deny, got $rc"
  assert_contains "$out" '[subagent-dispatch]' "ordinary Claude delegation deny lost its reason"
  pass "subagent guard --cursor: native behavior stays strict while Claude suppresses partial Cursor-versioned objects"
}

test_cursor_malformed_transport_fails_open() {
  local payload out rc
  for payload in \
    '{not-json' \
    '{}' \
    '{"hook_event_name":"preToolUse","cursor_version":"2.1.0","tool_name":"Agent","tool_input":[]}' \
    '{"hook_event_name":"stop","cursor_version":"2.1.0","tool_name":"Agent","tool_input":{}}'
  do
    rc=0
    out=$(printf '%s' "$payload" \
      | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
        "$CHECK" --cursor 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "invalid Cursor delegation payload must fail open, got $rc"
    [ -z "$out" ] || fail "invalid Cursor delegation payload must be silent: $out"
  done
  pass "subagent guard --cursor: malformed and wrong-event payloads fail open silently"
}

test_malformed_transport_fails_open() {
  local rc payload
  for payload in '{not-json' '' '{}' '{"tool_name":null}'; do
    rc=0
    : > "$OUT"; : > "$ERR"
    printf '%s' "$payload" \
      | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
        "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
    [ "$rc" -eq 0 ] || fail "malformed transport must fail open, payload '$payload' gave exit $rc"
    [ ! -s "$OUT" ] || fail "fail-open path wrote stdout for payload '$payload'"
  done
  pass "malformed, empty, and tool-name-less payloads fail open rather than blocking every tool call"
}

test_missing_jq_stdin_transport_fails_open() {
  local fakebin="$TMP_ROOT/no-jq-bin" bash_bin cat_bin rc=0
  bash_bin=$(command -v bash) || fail "test needs bash to simulate the hook shebang"
  cat_bin=$(command -v cat) || fail "test needs cat to feed stdin without jq"
  mkdir -p "$fakebin"
  ln -sf "$bash_bin" "$fakebin/bash"
  ln -sf "$cat_bin" "$fakebin/cat"
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Agent"}' \
    | env PATH="$fakebin" FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "missing jq transport must fail open, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "missing jq fail-open path wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "missing jq fail-open path wrote stderr: $(cat "$ERR")"
  pass "missing jq for stdin transport fails open rather than denying every tool call"
}

test_guard_denies_every_currently_known_delegation_tool
test_guard_denies_hypothetical_future_tools
test_guard_allows_ordinary_and_observe_only_tools
test_guard_allows_session_local_todo_tools
test_plan_only_exclusion_is_exact_name
test_guard_never_classifies_mcp_tools
test_cursor_native_mcp_namespace_is_exempt_only_with_prefix
test_deny_message_defers_to_intake_classification
test_escape_hatch_allows_deliberate_use
test_task_worktree_and_non_firstmate_repo_are_inert
test_secondmate_home_is_in_scope
test_stdin_transports_and_output_shapes
test_cursor_native_deny_allow_and_duplicate_suppression
test_cursor_malformed_transport_fails_open
test_malformed_transport_fails_open
test_missing_jq_stdin_transport_fails_open
