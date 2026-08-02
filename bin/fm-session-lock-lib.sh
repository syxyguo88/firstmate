#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Known non-Cursor harness command names; extend when a new adapter is verified.
# Cursor stays out of this broad regex because its official command is the
# generic name `agent` and requires the exact matcher below.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# True when command/argv carry explicit Cursor agent process identity.
# Exact cursor-agent basenames are authoritative. The official generic `agent`
# must have the matching agent launch name as argv[0], optionally followed by
# the verified --use-system-ca flag, then the versioned Cursor index.js entry.
# Legacy Node must have that index.js as its immediate entry-script argument;
# later argv mentions do not count. This marker-independent form is used when
# checking an external lock-holder PID.
fm_cursor_agent_args_match() {
  local comm=$1 args=$2 argv0 first second rest entry
  local IFS=$' \t\n'
  read -r argv0 first second rest <<<"$args"
  [ "$(basename -- "$argv0")" = "$(basename -- "$comm")" ] || return 1
  if [ "$first" = "--use-system-ca" ]; then
    entry=$second
  else
    entry=$first
  fi
  printf '%s\n' "$entry" \
    | grep -qE '^[^[:space:]]*/cursor-agent/versions/[^/[:space:]]+/index\.js$'
}

fm_cursor_explicit_process_matches() {
  local comm=$1 args=$2 bc
  bc=$(basename -- "$comm")
  case "$bc" in
    cursor-agent)
      return 0
      ;;
    agent)
      fm_cursor_agent_args_match "$comm" "$args"
      ;;
    node*)
      printf '%s\n' "$args" \
        | grep -qE '^([^[:space:]]*/)?node[^/[:space:]]*[[:space:]]+[^[:space:]]*/cursor-agent/versions/[^/[:space:]]+/index\.js([[:space:]]|$)'
      ;;
    *)
      return 1
      ;;
  esac
}

# True when one process in the current ancestry is Cursor.
# The generic official `agent` name additionally requires the inherited Cursor
# marker. This keeps marker-only environments and ordinary agent processes from
# claiming current-session identity while external holder checks remain stable.
fm_cursor_process_matches() {
  local comm=$1 args=$2
  case "$(basename -- "$comm")" in
    agent)
      [ "${CURSOR_AGENT:-}" = "1" ] || return 1
      ;;
  esac
  fm_cursor_explicit_process_matches "$comm" "$args"
}

# Walk the current process ancestry (up to 16 hops) and print a harness pid.
# For every harness except Claude, the first match wins (innermost pid), which
# is where e.g. Pi's shared signed-wrapper ancestry actually holds the session:
# a "pi-signed" launcher can be the direct parent of the inner "pi" engine
# pid that owns the lock, and the wrapper pid above it is not that owner.
# Claude Code's bg-spare hook worker chain is the opposite shape: it nests
# several claude-named processes directly parent-child with no non-harness
# process between them, and the lock is held by the outermost pid of that
# run. So once a claude-named match is found, this keeps walking past it
# looking for a still-more-ancestral claude-named match, and stops the
# instant a non-match follows - never walking past that gap to an unrelated
# claude-named process further up the real process tree (e.g. the live
# session that launched a test as its own subprocess). The harness pid lives
# as long as the session, unlike the transient subshell pid of any one tool
# call.
fm_harness_ancestry_pid() {
  local pid=$$ comm args best='' bc extending=0 hit=0 is_claude=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    bc=$(basename -- "$comm")
    hit=0; is_claude=0
    if fm_cursor_process_matches "$comm" "$args"; then
      hit=1
    elif printf '%s' "$bc" | grep -qE "$FM_HARNESS_RE"; then
      hit=1
      case "$bc" in *claude*) is_claude=1 ;; esac
    else
      # Bare interpreter (e.g. node): match the harness name in its script path.
      case "$comm" in
        *node*|*python*)
          if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
            hit=1
            case "$args" in *claude*) is_claude=1 ;; esac
          fi
          ;;
      esac
    fi
    if [ "$hit" -eq 1 ]; then
      best="$pid"
      if [ "$is_claude" -eq 1 ]; then
        extending=1
      else
        break
      fi
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ -n "$best" ] && { echo "$best"; return 0; }
  return 1
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  if fm_cursor_explicit_process_matches "$comm" "$args"; then
    return 0
  fi
  if printf '%s' "$(basename -- "$comm")" | grep -qE "$FM_HARNESS_RE"; then
    return 0
  fi
  case "$comm" in
    *node*|*python*)
      printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"
      ;;
    *) return 1 ;;
  esac
}

# True when state dir $1 holds a session lock whose pid is the harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. A missing lock, a lock held by another live harness, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid my_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ]
}
