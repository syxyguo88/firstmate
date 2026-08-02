#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of behavior suite
# selection, portable lane composition, proven-isolated --jobs, timing markers,
# JSON artifacts, coverage guard, and aggregate exit status.
#
# These tests intentionally exercise the runner with fixtures, --list, and
# focused scheduler checks, not the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

without_cursor_live_env() (
  unset FM_CURSOR_LIVE_E2E FM_CURSOR_CLI_CONTRACT_E2E
  "$@"
)

test_list_all_exact_suite_coverage() {
  local listed expected missing extra f
  listed=$(without_cursor_live_env "$RUNNER" --list --all | LC_ALL=C sort)
  expected=$(
    for f in "$ROOT"/tests/*.test.sh; do
      [ -f "$f" ] || continue
      printf 'tests/%s\n' "$(basename "$f")"
    done | LC_ALL=C sort
  )
  [ -n "$listed" ] || fail "--list --all printed nothing"
  missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  [ -z "$missing" ] || fail "--list --all missing scripts: $missing"
  [ -z "$extra" ] || fail "--list --all unexpected scripts: $extra"
  # No duplicates.
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = \
    "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" ] \
    || fail "--list --all must not duplicate scripts"
  pass "exact suite coverage: --all lists every tests/*.test.sh once"
}

test_family_selection() {
  local listed line cursor_listed live_listed
  listed=$(without_cursor_live_env "$RUNNER" --list --family pure-contract-unit)
  [ -n "$listed" ] || fail "--family pure-contract-unit selected nothing"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-test-run.test.sh' \
    || fail "pure-contract-unit must include fm-test-run.test.sh"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-cursor-primary-hooks.test.sh' \
    || fail "pure-contract-unit must include fm-cursor-primary-hooks.test.sh"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-cursor-live-contract.test.sh' \
    || fail "pure-contract-unit must include fm-cursor-live-contract.test.sh"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) ;;
      *) fail "family selection produced non-test path: $line" ;;
    esac
  done <<<"$listed"
  # Family mode must not equal the complete suite for a narrow family.
  local all_count fam_count
  all_count=$(without_cursor_live_env "$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] \
    || fail "pure-contract-unit must be a proper subset of --all"
  cursor_listed=$(without_cursor_live_env "$RUNNER" --list --family cursor-acp)
  printf '%s\n' "$cursor_listed" | grep -Fxq 'tests/fm-cursor-acp-bridge.test.sh' \
    || fail "cursor-acp family must include its hermetic bridge suite, got: $cursor_listed"
  printf '%s\n' "$cursor_listed" | grep -Fxq 'tests/fm-cursor-runtime-wiring.test.sh' \
    || fail "cursor-acp family must include Cursor runtime wiring, got: $cursor_listed"
  [ "$(printf '%s\n' "$cursor_listed" | wc -l | tr -d ' ')" = 2 ] \
    || fail "cursor-acp family should contain exactly bridge + runtime suites, got: $cursor_listed"
  without_cursor_live_env "$RUNNER" --list-families | grep -Fxq cursor-acp \
    || fail "--list-families must advertise cursor-acp"
  live_listed=$(without_cursor_live_env "$RUNNER" --list --family live-harness-optin)
  for line in \
    tests/fm-cursor-primary-live-e2e.test.sh \
    tests/fm-cursor-acp-live-e2e.test.sh \
    tests/fm-cursor-acp-cli-contract-live-e2e.test.sh; do
    printf '%s\n' "$live_listed" | grep -Fxq "$line" \
      || fail "live-harness-optin must include $line, got: $live_listed"
  done
  pass "family selection returns a proper subset of the suite"
}

test_cursor_live_default_skip_contract() {
  local tmp out json script first expected rc
  local -a scripts=(
    tests/fm-cursor-primary-live-e2e.test.sh
    tests/fm-cursor-acp-live-e2e.test.sh
    tests/fm-cursor-acp-cli-contract-live-e2e.test.sh
  )
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-cursor-live.XXXXXX")
  for script in "${scripts[@]}"; do
    [ -f "$ROOT/$script" ] || { rm -rf "$tmp"; fail "$script is missing"; }
    set +e
    out=$(without_cursor_live_env bash "$ROOT/$script" 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 0 ] \
      || { rm -rf "$tmp"; fail "$script default gate exited $rc: $out"; }
    first=$(printf '%s\n' "$out" | awk 'NF { print; exit }')
    case "$script" in
      tests/fm-cursor-acp-cli-contract-live-e2e.test.sh)
        expected='skip: set FM_CURSOR_CLI_CONTRACT_E2E=1'
        ;;
      *)
        expected='skip: set FM_CURSOR_LIVE_E2E=1'
        ;;
    esac
    case "$first" in
      "$expected"*) ;;
      *) rm -rf "$tmp"; fail "$script first line must start '$expected', got: $first" ;;
    esac
  done

  json="$tmp/timing.json"
  without_cursor_live_env "$RUNNER" --json "$json" "${scripts[@]}" >"$tmp/out" 2>"$tmp/err" \
    || { rm -rf "$tmp"; fail "runner must treat default Cursor live gates as successful skips"; }
  python3 - "$json" <<'PY' \
    || { rm -rf "$tmp"; fail "Cursor live runner metadata did not preserve opt-in gate skips"; }
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(doc["scripts"]) == 3, doc
for script in doc["scripts"]:
    assert script["family"] == "live-harness-optin", script
    assert script["expected_gate_skip"] == "optin-env", script
    assert script["gate_skip"] is True, script
assert doc["summary"]["failed"] == 0, doc
assert doc["summary"]["skipped_gate"] == 3, doc
PY
  rm -rf "$tmp"
  pass "Cursor live gates default to first-line opt-in skips with honest runner metadata"
}

test_nested_runner_commands_clear_cursor_live_ambient() {
  local probe
  probe=$(
    FM_CURSOR_LIVE_E2E=1 FM_CURSOR_CLI_CONTRACT_E2E=1 \
      without_cursor_live_env sh -c \
        'printf "%s:%s\n" "${FM_CURSOR_LIVE_E2E-unset}" "${FM_CURSOR_CLI_CONTRACT_E2E-unset}"'
  ) || fail "Cursor-safe nested command wrapper failed"
  [ "$probe" = "unset:unset" ] \
    || fail "Cursor-safe nested command wrapper leaked ambient live gates: $probe"

  python3 - "${BASH_SOURCE[0]}" <<'PY' || fail "a nested runner/default-skip invocation bypasses without_cursor_live_env"
import sys

path = sys.argv[1]
bad = []
for number, line in enumerate(open(path, encoding="utf-8"), 1):
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    exempt = stripped.startswith(
        ("assert_", "[ -x ", "cp ", "chmod ", "('", "or (")
    )
    invokes = (
        ('"$RUNNER"' in line and not exempt)
        or ('"$runner"' in line and not exempt)
        or ("bin/fm-test-run.sh --" in line and not exempt)
        or ('bash "$ROOT/$script"' in line and not exempt)
    )
    if invokes and "without_cursor_live_env" not in line:
        bad.append((number, stripped))
if bad:
    for number, line in bad:
        print(f"{number}: {line}", file=sys.stderr)
    raise SystemExit(1)
PY
  pass "nested runner and default-skip commands clear ambient Cursor live gates"
}

test_single_script_selection() {
  local listed
  listed=$(without_cursor_live_env "$RUNNER" --list tests/fm-lint.test.sh)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "single-script list expected tests/fm-lint.test.sh, got: $listed"
  pass "single-script selection lists exactly that path"
}

test_changed_file_selection_is_conservative() {
  local listed all_count fam_count listed_count
  # A path-mapped pure unit should not expand to --all.
  listed=$(without_cursor_live_env "$RUNNER" --list --family pure-contract-unit)
  all_count=$(without_cursor_live_env "$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] || fail "changed-informed pure family still full suite"
  # Directly exercise --changed: empty or partial selection is ok; must not
  # exceed the suite and must never silently become --all by accident.
  listed=$(without_cursor_live_env "$RUNNER" --list --changed --base HEAD 2>/dev/null || true)
  if [ -n "$listed" ]; then
    listed_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
    [ "$listed_count" -le "$all_count" ] || fail "changed selection larger than suite"
  fi
  # A single test path selects only that script (same contract as a
  # tests/*.test.sh change entry in the map).
  listed=$(without_cursor_live_env "$RUNNER" --list tests/fm-brief.test.sh)
  [ "$listed" = "tests/fm-brief.test.sh" ] \
    || fail "test-file-only change contract should select one script"
  pass "changed-file selection stays conservative (never silent full suite)"
}

init_changed_fixture_repo() {
  local repo=$1 script
  mkdir -p "$repo/bin/backends" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-brief.test.sh \
    fm-ask-user-authority.test.sh \
    fm-cd-pretool-check.test.sh \
    fm-cursor-acp-bridge.test.sh \
    fm-cursor-acp-cli-contract-live-e2e.test.sh \
    fm-cursor-acp-live-e2e.test.sh \
    fm-cursor-live-contract.test.sh \
    fm-cursor-primary-live-e2e.test.sh \
    fm-cursor-primary-hooks.test.sh \
    fm-cursor-runtime-wiring.test.sh \
    fm-daemon.test.sh \
    fm-claude-stop-autoarm.test.sh \
    fm-busy-state.test.sh \
    fm-backend-herdr-smoke.test.sh \
    fm-pending-reply.test.sh \
    fm-secondmate-liveness.test.sh \
    fm-secondmate-safety.test.sh \
    fm-send-secondmate-marker.test.sh \
    fm-session-start.test.sh \
    fm-afk-pi-herdr-return-e2e.test.sh \
    fm-backend.test.sh \
    fm-pr-merge.test.sh \
    fm-pi-watch-extension.test.sh \
    fm-afk-return.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-backend-cmux.test.sh \
    fm-backend-zellij.test.sh \
    fm-backend-orca.test.sh; do
    printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
  : >"$repo/tests/lib.sh"
  : >"$repo/tests/fm-backend-herdr-eventwait.test.py"
  : >"$repo/bin/fm-backend.sh"
  : >"$repo/bin/fm-arm-pretool-check.sh"
  : >"$repo/bin/fm-cd-pretool-check.sh"
  : >"$repo/bin/fm-harness.sh"
  : >"$repo/bin/fm-bootstrap.sh"
  : >"$repo/bin/fm-busy-lib.sh"
  : >"$repo/bin/fm-cursor-acp-bridge.mjs"
  : >"$repo/bin/fm-operational-input.sh"
  : >"$repo/bin/fm-pending-reply-lib.sh"
  : >"$repo/bin/fm-primary-scope-lib.sh"
  : >"$repo/bin/fm-send.sh"
  : >"$repo/bin/fm-session-lock-lib.sh"
  : >"$repo/bin/fm-session-start.sh"
  : >"$repo/bin/fm-sessionstart-nudge.sh"
  : >"$repo/bin/fm-spawn.sh"
  : >"$repo/bin/fm-subagent-pretool-check.sh"
  : >"$repo/bin/fm-supervision-instructions.sh"
  : >"$repo/bin/fm-supervision-lib.sh"
  : >"$repo/bin/fm-supervisor-target-lib.sh"
  : >"$repo/bin/fm-teardown.sh"
  : >"$repo/bin/fm-turnend-guard.sh"
  : >"$repo/bin/backends/herdr.sh"
  : >"$repo/bin/backends/tmux.sh"
  : >"$repo/bin/unmapped-source.sh"
  printf '# .claude/settings.json\n# .pi/extensions/fm-primary-turnend-guard.ts\n' \
    >>"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '# .pi/extensions/fm-primary-pi-watch.ts\n' >>"$repo/tests/fm-pi-watch-extension.test.sh"
  mkdir -p "$repo/.agents/skills/example" "$repo/.claude" "$repo/.cursor" \
    "$repo/.pi/extensions" "$repo/docs/supervision-protocols" "$repo/src"
  : >"$repo/.agents/skills/example/SKILL.md"
  : >"$repo/.claude/settings.json"
  : >"$repo/.cursor/hooks.json"
  ln -s ../.agents/skills "$repo/.cursor/skills"
  : >"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : >"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  : >"$repo/docs/supervision-protocols/cursor.md"
  : >"$repo/src/unmapped.ts"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
}

assert_harness_identity_changed_selection() {
  local listed=$1 source=$2
  assert_contains "$listed" "tests/fm-brief.test.sh" \
    "$source change must select pure-contract-unit"
  assert_contains "$listed" "tests/fm-session-start.test.sh" \
    "$source change must select session-bootstrap"
  assert_contains "$listed" "tests/fm-daemon.test.sh" \
    "$source change must select watcher-wake-lock"
  assert_contains "$listed" "tests/fm-claude-stop-autoarm.test.sh" \
    "$source change must select the Stop autoarm lock contract"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" \
    "$source change must select secondmate"
  assert_contains "$listed" "tests/fm-backend.test.sh" \
    "$source change must select backend-dispatch"
}

assert_cursor_live_changed_selection() {
  local listed=$1 source=$2 script
  for script in \
    tests/fm-cursor-primary-live-e2e.test.sh \
    tests/fm-cursor-acp-live-e2e.test.sh \
    tests/fm-cursor-acp-cli-contract-live-e2e.test.sh; do
    assert_contains "$listed" "$script" \
      "$source change must conservatively select live Cursor gate $script"
  done
}

test_changed_dependency_selection_and_unmapped_failure() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/bin/fm-cursor-acp-bridge.mjs"
  listed=$(cd "$repo" && without_cursor_live_env bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-cursor-acp-bridge.test.sh" \
    "bridge source change must select the bridge suite"
  assert_contains "$listed" "tests/fm-cursor-runtime-wiring.test.sh" \
    "bridge source change must select runtime wiring"
  assert_contains "$listed" "tests/fm-secondmate-liveness.test.sh" \
    "bridge process-title change must select secondmate liveness coverage"
  assert_cursor_live_changed_selection "$listed" "bridge source"
  git -C "$repo" add bin/fm-cursor-acp-bridge.mjs
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm cursor-acp-map

  for source in \
    bin/fm-backend.sh \
    bin/fm-spawn.sh \
    bin/fm-busy-lib.sh \
    bin/fm-send.sh \
    bin/fm-teardown.sh \
    bin/fm-bootstrap.sh \
    bin/backends/tmux.sh \
    bin/backends/herdr.sh; do
    printf '\n' >>"$repo/$source"
    listed=$(cd "$repo" && without_cursor_live_env bin/fm-test-run.sh --list --changed --base HEAD)
    assert_contains "$listed" "tests/fm-cursor-runtime-wiring.test.sh" \
      "$source change must select Cursor runtime wiring"
    assert_cursor_live_changed_selection "$listed" "$source"
    case "$source" in
      bin/fm-busy-lib.sh)
        assert_contains "$listed" "tests/fm-busy-state.test.sh" \
          "$source change must select Cursor busy-state trust coverage"
        ;;
      bin/fm-send.sh)
        assert_contains "$listed" "tests/fm-send-secondmate-marker.test.sh" \
          "$source change must select secondmate marker transactions"
        assert_contains "$listed" "tests/fm-pending-reply.test.sh" \
          "$source change must select pending-reply recovery coverage"
        ;;
      bin/fm-backend.sh|bin/fm-bootstrap.sh|bin/backends/tmux.sh|bin/backends/herdr.sh)
        assert_contains "$listed" "tests/fm-secondmate-liveness.test.sh" \
          "$source change must select secondmate liveness recovery coverage"
        ;;
    esac
    git -C "$repo" add "$source"
    git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm "cursor-runtime-map-${source//\//-}"
  done

  printf '\n' >>"$repo/bin/fm-pending-reply-lib.sh"
  listed=$(cd "$repo" && without_cursor_live_env bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pending-reply.test.sh" \
    "fm-pending-reply-lib.sh change must select pending-reply recovery coverage"
  git -C "$repo" add bin/fm-pending-reply-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm pending-reply-map

  printf '\n' >>"$repo/bin/fm-session-lock-lib.sh"
  listed=$(cd "$repo" && without_cursor_live_env bin/fm-test-run.sh --list --changed --base HEAD)
  assert_harness_identity_changed_selection "$listed" "fm-session-lock-lib.sh"
  git -C "$repo" add bin/fm-session-lock-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm session-lock-map

  printf '\n' >>"$repo/bin/fm-harness.sh"
  listed=$(cd "$repo" && without_cursor_live_env bin/fm-test-run.sh --list --changed --base HEAD)
  assert_harness_identity_changed_selection "$listed" "fm-harness.sh"
  git -C "$repo" add bin/fm-harness.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm harness-map

  printf '\n' >>"$repo/.cursor/hooks.json"
  listed=$(cd "$repo" && without_cursor_live_env bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-cursor-primary-hooks.test.sh" \
    "Cursor hooks change must select its native contract suite"
  assert_contains "$listed" "tests/fm-session-start.test.sh" \
    "Cursor hooks change must select session-bootstrap coverage"
  assert_contains "$listed" "tests/fm-daemon.test.sh" \
    "Cursor hooks change must select watcher-wake-lock coverage"
  assert_cursor_live_changed_selection "$listed" "Cursor hooks"
  git -C "$repo" add .cursor/hooks.json
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm cursor-hooks-map

  for source in \
    bin/fm-sessionstart-nudge.sh \
    bin/fm-arm-pretool-check.sh \
    bin/fm-cd-pretool-check.sh \
    bin/fm-subagent-pretool-check.sh \
    bin/fm-turnend-guard.sh \
    bin/fm-primary-scope-lib.sh \
    bin/fm-operational-input.sh \
    bin/fm-session-start.sh \
    bin/fm-supervision-instructions.sh \
    bin/fm-supervision-lib.sh \
    docs/supervision-protocols/cursor.md; do
    printf '\n' >>"$repo/$source"
    listed=$(cd "$repo" && without_cursor_live_env bin/fm-test-run.sh --list --changed --base HEAD)
    assert_cursor_live_changed_selection "$listed" "$source"
    git -C "$repo" add "$source"
    git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm "cursor-hook-map-${source//\//-}"
  done

  printf '\n' >>"$repo/tests/lib.sh"
  listed=$(cd "$repo" && without_cursor_live_env bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "shared helper selects pr-forge dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "shared helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "shared helper selects snapshot dependents"
  git -C "$repo" add tests/lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm helper-change

  printf '\n' >>"$repo/tests/fm-backend-herdr-eventwait.test.py"
  listed=$(cd "$repo" && without_cursor_live_env bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" "eventwait test selects Herdr coverage"
  assert_contains "$listed" "tests/fm-backend.test.sh" "eventwait test selects backend coverage"
  git -C "$repo" add tests/fm-backend-herdr-eventwait.test.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm eventwait-change

  printf '\n' >>"$repo/bin/fm-supervisor-target-lib.sh"
  listed=$(cd "$repo" && without_cursor_live_env bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-daemon.test.sh" "supervisor target selects daemon coverage"
  assert_contains "$listed" "tests/fm-afk-return.test.sh" "supervisor target selects afk coverage"
  git -C "$repo" add bin/fm-supervisor-target-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm supervisor-change

  printf '\n' >>"$repo/.agents/skills/example/SKILL.md"
  printf '\n' >>"$repo/.claude/settings.json"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  listed=$(cd "$repo" && without_cursor_live_env bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-ask-user-authority.test.sh" "skill source selects pure contract coverage"
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" "Claude and Pi source selects hook coverage"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" "Pi source selects watcher coverage"
  git -C "$repo" add .agents .claude .pi
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm non-bin-source-change

  printf '\n' >>"$repo/src/unmapped.ts"
  set +e
  (cd "$repo" && without_cursor_live_env bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unmapped changed source must fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: src/unmapped.ts' "$tmp/err" \
    || fail "unmapped changed source failure is not actionable: $(cat "$tmp/err")"
  rm -rf "$tmp"
  pass "changed selection covers dependents and fails closed for unmapped source"
}

test_empty_selection_emits_summary() {
  local tmp repo out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-empty.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf 'documentation only\n' >"$repo/README.md"
  out=$(cd "$repo" && without_cursor_live_env bin/fm-test-run.sh --changed --base HEAD --json "$tmp/artifacts/timing.json" 2>"$tmp/err") \
    || fail "empty valid changed selection must pass"
  [ "$out" = "FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0" ] \
    || fail "empty selection summary is missing or non-deterministic: $out"
  json="$tmp/artifacts/timing.json"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["summary"] == {"duration_ms": 0, "failed": 0, "skipped_gate": 0, "total": 0}
assert doc["scripts"] == []
assert doc["families"] == []
' "$json" || { rm -rf "$tmp"; fail "empty selection JSON summary is wrong"; }
  rm -rf "$tmp"
  pass "empty changed selection emits deterministic text and JSON summaries"
}

test_timing_markers_and_json() {
  local tmp fixture out json begin_n end_n summary
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-timing.XXXXXX")
  fixture="$tmp/ok.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  chmod +x "$fixture"
  without_cursor_live_env "$RUNNER" --json "$json" "$fixture" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "runner should pass on a green fixture"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$out" || true)
  [ "$begin_n" -eq 1 ] || fail "expected one FM_TEST_BEGIN, got $begin_n"
  [ "$end_n" -eq 1 ] || fail "expected one FM_TEST_END, got $end_n"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$out" \
    || fail "BEGIN line missing family/expected_gate_skip: $(grep '^FM_TEST_BEGIN' "$out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false$' "$out" \
    || fail "END line missing exit/duration/gate_skip: $(grep '^FM_TEST_END' "$out")"
  summary=$(grep '^FM_TEST_SUMMARY ' "$out" || true)
  assert_contains "$summary" "total=1" "summary total"
  assert_contains "$summary" "failed=0" "summary failed"
  assert_contains "$summary" "skipped_gate=0" "summary skipped_gate"
  grep -q '^FM_TEST_SLOWEST rank=1 ' "$out" \
    || fail "expected FM_TEST_SLOWEST rank=1"
  [ -f "$json" ] || fail "JSON timing artifact was not written"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$json" \
    || fail "JSON timing artifact is not valid JSON"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert "scripts" in doc and len(doc["scripts"]) == 1, doc
assert doc["scripts"][0]["exit"] == 0
assert doc["scripts"][0]["gate_skip"] is False
assert doc["summary"]["total"] == 1
assert doc["summary"]["failed"] == 0
assert "duration_ms" in doc["scripts"][0]
assert "family" in doc["scripts"][0]
' "$json" || { rm -rf "$tmp"; fail "JSON timing artifact missing required fields"; }
  rm -rf "$tmp"
  pass "timing markers and JSON artifact are valid"
}

test_aggregate_exit_behavior() {
  local tmp pass_f fail_f rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-agg.XXXXXX")
  pass_f="$tmp/pass.test.sh"
  fail_f="$tmp/fail.test.sh"
  cat >"$pass_f" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
exit 0
SH
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
echo "not ok - fail"
exit 1
SH
  chmod +x "$pass_f" "$fail_f"
  set +e
  without_cursor_live_env "$RUNNER" "$pass_f" "$fail_f" >"$tmp/out.txt" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate exit must be non-zero when any script fails"
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out.txt" \
    || fail "summary should report total=2 failed=1: $(grep FM_TEST_SUMMARY "$tmp/out.txt")"
  # All-green stays 0.
  set +e
  without_cursor_live_env "$RUNNER" "$pass_f" >"$tmp/out2.txt" 2>"$tmp/err2.txt"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "aggregate exit must be 0 when every script passes"; }
  rm -rf "$tmp"
  pass "aggregate exit reflects any script failure"
}

test_gate_skip_accounting() {
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  without_cursor_live_env "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "gate-skip fixture must exit 0 from the runner"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$out" \
    || fail "END must mark gate_skip=true: $(grep '^FM_TEST_END' "$out")"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$out" \
    || fail "summary must count skipped_gate=1: $(grep FM_TEST_SUMMARY "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["scripts"][0]["gate_skip"] is True
assert doc["summary"]["skipped_gate"] == 1
assert doc["summary"]["failed"] == 0
' "$json" || { rm -rf "$tmp"; fail "JSON gate_skip accounting is wrong"; }
  rm -rf "$tmp"
  pass "gate-skip accounting is honest and non-failing"
}

test_fail_on_gate_skip_token() {
  local tmp skip_f out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fail-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  set +e
  without_cursor_live_env "$RUNNER" --fail-on-gate-skip 'herdr not found' "$skip_f" >"$out" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fail-on-gate-skip must make herdr-not-found a hard failure"
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$out" \
    || fail "summary must report failed=1 under fail-on-gate-skip: $(grep FM_TEST_SUMMARY "$out")"
  grep -q 'required gate skip token' "$tmp/err.txt" \
    || fail "runner must log the required gate skip token"
  rm -rf "$tmp"
  pass "fail-on-gate-skip converts herdr-not-found into a hard failure"
}

test_exclude_family() {
  local listed
  listed=$(without_cursor_live_env "$RUNNER" --list --all --exclude-family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "exclude-family real-herdr-gated left a real-herdr script"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-lint.test.sh' \
    || fail "exclude-family must retain pure-contract-unit scripts"
  # Explicit family mode still works; exclude of a different family is a no-op.
  listed=$(without_cursor_live_env "$RUNNER" --list --family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "family real-herdr-gated must list smoke test"
  pass "exclude-family drops the named primary family after selection"
}

test_portable_shard_union_and_coverage_guard() {
  local s1 s2 proven serial herdr all_count union_count overlap out first
  s1=$(without_cursor_live_env "$RUNNER" --list --lane portable-parallel-1)
  s2=$(without_cursor_live_env "$RUNNER" --list --lane portable-parallel-2)
  proven=$(without_cursor_live_env "$RUNNER" --list --proven-isolated)
  serial=$(without_cursor_live_env "$RUNNER" --list --lane portable-serial)
  herdr=$(without_cursor_live_env "$RUNNER" --list --family real-herdr-gated)
  [ -n "$s1" ] && [ -n "$s2" ] || fail "portable parallel shards must be non-empty"
  # Shards disjoint.
  overlap=$(comm -12 <(printf '%s\n' "$s1" | LC_ALL=C sort) <(printf '%s\n' "$s2" | LC_ALL=C sort) || true)
  [ -z "$overlap" ] || fail "portable parallel shards overlap: $overlap"
  # Union of shards equals proven-isolated.
  [ "$(printf '%s\n' "$s1" "$s2" | LC_ALL=C sort -u)" = \
    "$(printf '%s\n' "$proven" | LC_ALL=C sort -u)" ] \
    || fail "shard union must equal proven-isolated set"
  # No herdr in portable lanes.
  printf '%s\n' "$s1" "$s2" "$serial" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "portable lanes must not include real-herdr-gated smoke"
  printf '%s\n' "$herdr" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "herdr family must include smoke"
  out=$(without_cursor_live_env "$RUNNER" --check-coverage)
  assert_contains "$out" "FM_TEST_COVERAGE ok" "coverage guard success marker"
  all_count=$(without_cursor_live_env "$RUNNER" --list --all | wc -l | tr -d ' ')
  union_count=$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$union_count" = "$all_count" ] \
    || fail "union of lanes ($union_count) must equal --all ($all_count)"
  # No duplicates across the four partitions.
  [ "$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" = "0" ] \
    || fail "lanes must not duplicate scripts"
  # LPT order: first script of shard 1 is the longest proven script.
  first=$(printf '%s\n' "$s1" | head -n 1)
  [ "$first" = "tests/fm-x-mode.test.sh" ] \
    || fail "shard 1 must start with the longest proven script, got $first"
  pass "portable shard union, disjointness, and coverage guard hold"
}

test_jobs_requires_proven_isolated() {
  local tmp rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs.XXXXXX")
  set +e
  without_cursor_live_env "$RUNNER" --jobs 2 --lane portable-serial >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with portable-serial must refuse (exit 2), got $rc"
  grep -Fq 'not in the proven-isolated set' "$tmp/err" \
    || fail "--jobs refusal message missing: $(cat "$tmp/err")"
  set +e
  without_cursor_live_env "$RUNNER" --jobs 2 tests/fm-watcher-lock.test.sh >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs on watcher-lock must refuse, got $rc"
  rm -rf "$tmp"
  pass "--jobs refuses non-proven / stateful selections"
}

test_jobs_parallel_scheduler_and_failure_propagation() {
  local tmp repo runner evidence fake_bin a b c d rc begin_n end_n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-sched.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  fake_bin="$tmp/fake-bin"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  c=tests/fm-lint.test.sh
  d=tests/fm-supervision-instructions.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fake_bin"
  cp "$RUNNER" "$runner"
  cat >"$fake_bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
  printf '700\n'
  exit 0
fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
  printf '  File: "%s"\n    ID: fake Namelen: 255 Type: ext2/ext3\n700\n' "$3"
  exit 0
fi
exit 1
SH
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
sleep 0.5
touch "$SCHED_EVIDENCE/slow-done"
echo "ok - slow fixture"
SH
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
sleep 0.05
echo "ok - fast fixture"
SH
  cat >"$repo/$c" <<'SH'
#!/usr/bin/env bash
if [ -e "$SCHED_EVIDENCE/slow-done" ]; then
  echo "not ok - scheduler waited for oldest worker"
  exit 1
fi
echo "ok - replacement fixture started before slow fixture finished"
SH
  chmod +x "$runner" "$repo/$a" "$repo/$b" "$repo/$c" "$fake_bin/stat"
  set +e
  without_cursor_live_env env PATH="$fake_bin:$PATH" SCHED_EVIDENCE="$evidence" "$runner" \
    --jobs 2 --json "$tmp/timing.json" \
    "$a" "$b" "$c" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "jobs=2 must refill the first completed slot"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$tmp/out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$tmp/out" || true)
  [ "$begin_n" -eq 3 ] || fail "expected 3 BEGIN markers, got $begin_n"
  [ "$end_n" -eq 3 ] || fail "expected 3 END markers, got $end_n"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0' "$tmp/out" \
    || fail "summary missing for jobs run: $(grep FM_TEST_SUMMARY "$tmp/out")"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==0
assert "jobs=2" in doc["selection"]
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "jobs JSON artifact wrong"; }

  # Non-proven path is refused before any worker starts (no race masking).
  cat >"$tmp/fail.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate fail"
exit 1
SH
  chmod +x "$tmp/fail.test.sh"
  set +e
  without_cursor_live_env "$runner" --jobs 2 "$a" "$tmp/fail.test.sh" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "jobs with non-proven fail fixture must refuse before run, got $rc"

  # Parallel failure propagation stays inside the private runner fixture.
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate proven-set fail"
exit 1
SH
  chmod +x "$repo/$b"
  rm -f "$evidence/slow-done"
  set +e
  without_cursor_live_env env SCHED_EVIDENCE="$evidence" "$runner" \
    --jobs 2 "$a" "$b" >"$tmp/out4" 2>"$tmp/err4"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "jobs aggregate must be non-zero when a proven worker fails"; }
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out4" \
    || { rm -rf "$tmp"; fail "jobs failure summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out4")"; }

  cat >"$repo/$d" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found" >&2
exit 0
SH
  chmod +x "$repo/$d"
  set +e
  without_cursor_live_env "$runner" --jobs 2 --fail-on-gate-skip 'herdr not found' "$d" >"$tmp/out5" 2>"$tmp/err5"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "parallel stderr gate skip must hard-fail"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out5" \
    || { rm -rf "$tmp"; fail "parallel stderr hard-fail summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out5")"; }

  without_cursor_live_env "$runner" --jobs 2 "$d" >"$tmp/out6" 2>"$tmp/err6" \
    || { rm -rf "$tmp"; fail "ordinary parallel stderr gate skip must remain successful"; }
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr gate skip was not recorded"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr skip summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out6")"; }

  rm -rf "$tmp"
  pass "jobs scheduler runs proven scripts; failure propagates; non-proven refused"
}

test_aggregate_json() {
  local tmp a b
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggjson.XXXXXX")
  cat >"$tmp/a.json" <<'JSON'
{
  "run_id": "a",
  "selection": "lane=portable-parallel-1",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:01:00Z",
  "summary": {"total": 1, "failed": 0, "skipped_gate": 0, "duration_ms": 1000},
  "scripts": [{"path": "tests/a.test.sh", "family": "pure-contract-unit", "duration_ms": 1000, "exit": 0, "gate_skip": false}]
}
JSON
  cat >"$tmp/b.json" <<'JSON'
{
  "run_id": "b",
  "selection": "lane=portable-serial",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:02:00Z",
  "summary": {"total": 2, "failed": 1, "skipped_gate": 0, "duration_ms": 2000},
  "scripts": [
    {"path": "tests/b.test.sh", "family": "afk", "duration_ms": 1500, "exit": 1, "gate_skip": false},
    {"path": "tests/c.test.sh", "family": "afk", "duration_ms": 500, "exit": 0, "gate_skip": false}
  ]
}
JSON
  out=$(without_cursor_live_env "$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json")
  assert_contains "$out" "FM_TEST_AGGREGATE lanes=2 total=3 failed=1" "aggregate summary line"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["kind"]=="aggregate"
assert doc["summary"]["lanes"]==2
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==1
assert doc["summary"]["critical_path_duration_ms"]==2000
assert len(doc["scripts"])==3
' "$tmp/out.json" || { rm -rf "$tmp"; fail "aggregate JSON shape wrong"; }
  rm -rf "$tmp"
  pass "aggregate-json merges lane timing artifacts"
}

test_list_all_exact_suite_coverage
test_family_selection
test_cursor_live_default_skip_contract
test_nested_runner_commands_clear_cursor_live_ambient
test_single_script_selection
test_changed_file_selection_is_conservative
test_changed_dependency_selection_and_unmapped_failure
test_empty_selection_emits_summary
test_timing_markers_and_json
test_aggregate_exit_behavior
test_gate_skip_accounting
test_fail_on_gate_skip_token
test_exclude_family
test_portable_shard_union_and_coverage_guard
test_jobs_requires_proven_isolated
test_jobs_parallel_scheduler_and_failure_propagation
test_aggregate_json
