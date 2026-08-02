#!/usr/bin/env bash
# Print the session-start instruction only for a genuine firstmate primary whose
# current harness session has not already acquired the home lock.
# Default and --claude modes preserve the raw operational nudge.
# --cursor accepts only a native Cursor sessionStart payload and returns its
# additional_context JSON shape.
# Every silence and error path exits 0 because session-start hooks must fail open.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MODE=default

for arg in "$@"; do
  case "$arg" in
    --claude)
      [ "$MODE" = default ] || { echo "usage: $(basename "$0") [--claude|--cursor]" >&2; exit 2; }
      MODE=claude
      ;;
    --cursor)
      [ "$MODE" = default ] || { echo "usage: $(basename "$0") [--claude|--cursor]" >&2; exit 2; }
      MODE=cursor
      ;;
    *)
      echo "usage: $(basename "$0") [--claude|--cursor]" >&2
      exit 2
      ;;
  esac
done

PAYLOAD=
if [ "$MODE" != default ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
fi

if [ "$MODE" = claude ] && command -v jq >/dev/null 2>&1; then
  if printf '%s' "$PAYLOAD" | jq -e '
    type == "object"
    and (.cursor_version | type == "string" and length > 0)
  ' >/dev/null 2>&1; then
    exit 0
  fi
fi

if [ "$MODE" = cursor ]; then
  command -v jq >/dev/null 2>&1 || exit 0
  printf '%s' "$PAYLOAD" | jq -e '
    type == "object"
    and .hook_event_name == "sessionStart"
    and (.cursor_version | type == "string" and length > 0)
    and (.session_id | type == "string" and length > 0)
    and (.is_background_agent | type == "boolean")
    and ((has("composer_mode") | not)
      or (.composer_mode == "agent" or .composer_mode == "ask" or .composer_mode == "edit"))
  ' >/dev/null 2>&1 || exit 0
fi

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

lock_is_in_ancestry() {
  local lock_pid pid=$$ _
  [ -f "$STATE/.lock" ] || return 1
  IFS= read -r lock_pid < "$STATE/.lock" 2>/dev/null || return 1
  case "$lock_pid" in
    ''|*[!0-9]*|1) return 1 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$lock_pid" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

lock_is_in_ancestry && exit 0
nudge=
fm_operational_input_encode session-start \
  "Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions." \
  nudge || exit 0
if [ "$MODE" = cursor ]; then
  jq -cn --arg additional_context "$nudge" '{additional_context:$additional_context}'
else
  printf '%s\n' "$nudge"
fi
exit 0
