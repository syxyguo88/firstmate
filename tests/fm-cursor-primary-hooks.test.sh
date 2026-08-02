#!/usr/bin/env bash
# Contract tests for Cursor's tracked primary project hooks and shared skills link.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOKS="$ROOT/.cursor/hooks.json"
SKILLS="$ROOT/.cursor/skills"

test_project_hook_schema_and_commands() {
  [ -f "$HOOKS" ] || fail "tracked Cursor project hooks are missing"
  jq -e '
    .version == 1
    and (.hooks | keys | sort) == ["preToolUse", "sessionStart", "stop"]
    and (.hooks.sessionStart | length) == 1
    and .hooks.sessionStart[0].timeout == 10
    and .hooks.sessionStart[0].command
      == "\"$CURSOR_PROJECT_DIR\"/bin/fm-sessionstart-nudge.sh --cursor"
    and (.hooks.preToolUse | length) == 3
    and .hooks.preToolUse[0].matcher == "Shell"
    and .hooks.preToolUse[0].command
      == "\"$CURSOR_PROJECT_DIR\"/bin/fm-arm-pretool-check.sh --cursor"
    and .hooks.preToolUse[1].matcher == "Shell"
    and .hooks.preToolUse[1].command
      == "\"$CURSOR_PROJECT_DIR\"/bin/fm-cd-pretool-check.sh --cursor"
    and .hooks.preToolUse[2].matcher == ".*"
    and .hooks.preToolUse[2].command
      == "\"$CURSOR_PROJECT_DIR\"/bin/fm-subagent-pretool-check.sh --cursor"
    and (.hooks.stop | length) == 1
    and .hooks.stop[0].timeout == 30
    and .hooks.stop[0].loop_limit == 3
    and .hooks.stop[0].command
      == "\"$CURSOR_PROJECT_DIR\"/bin/fm-turnend-guard.sh --cursor"
  ' "$HOOKS" >/dev/null || fail "Cursor hooks schema, matcher, timeout, loop limit, or anchored command is wrong"
  pass "Cursor project hooks register native sessionStart, preToolUse, and bounded stop commands"
}

test_shared_skills_link() {
  [ -L "$SKILLS" ] || fail ".cursor/skills must be a symlink"
  [ "$(readlink "$SKILLS")" = "../.agents/skills" ] \
    || fail ".cursor/skills target must be ../.agents/skills, got: $(readlink "$SKILLS")"
  pass "Cursor project skills link targets the shared .agents skills tree"
}

test_project_hook_schema_and_commands
test_shared_skills_link
