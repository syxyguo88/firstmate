#!/usr/bin/env bash
# bin/backends/tmux.sh - the tmux session-provider adapter.
#
# Reference backend (AGENTS.md section 8; data/fm-backend-design-d7). P1 moves
# the tmux command sequences that fm-send.sh, fm-peek.sh, fm-watch.sh,
# fm-spawn.sh, and fm-teardown.sh already ran inline into named functions
# here, running the EXACT same commands in the EXACT same order, so the
# default (tmux, `backend=` absent) path stays byte-identical. Sourced only
# through bin/fm-backend.sh's fm_backend_source, never directly.
#
# Worktree acquisition (running `treehouse get` inside the pane, and polling
# its cwd) is unchanged by this extraction: P1 scopes only the session
# provider, not the worktree provider, so fm-spawn.sh still drives that part
# inline with these same send/current-path primitives.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# already live in bin/fm-tmux-lib.sh, shared with the away-mode daemon
# (bin/fm-supervise-daemon.sh); this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than
# duplicating it, so the two consumers cannot drift apart.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"

# fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# fm-send.sh's and fm-peek.sh's own (until now duplicated) resolve().
fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# fm_backend_tmux_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's and fm-watch.sh's `tmux capture-pane -p -t "$T" -S -"$N"`.
fm_backend_tmux_capture() {  # <target> <lines>
  tmux capture-pane -p -t "$1" -S -"$2"
}

# fm_backend_tmux_send_key: one named key. Mirrors fm-send.sh's --key path:
# `tmux display-message -p -t "$T" '#{pane_id}' >/dev/null`, then
# `tmux send-keys -t "$T" "$2"`.
fm_backend_tmux_send_key() {  # <target> <key>
  tmux display-message -p -t "$1" '#{pane_id}' >/dev/null
  tmux send-keys -t "$1" "$2"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. Re-exports fm_tmux_submit_core (bin/fm-tmux-lib.sh) verbatim; see
# that file for the composer-verification contract and echoed verdicts.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Mirrors fm-spawn.sh's container-ensure block;
# prints the resolved session name.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
    printf 'firstmate'
  fi
}

# fm_backend_tmux_create_task: create the task's window in <proj-abs>,
# refusing an existing <window-name> in <session>. Mirrors fm-spawn.sh's
# duplicate-check-then-new-window sequence, including the exact error text
# (session:window, matching how fm-spawn.sh composed its own $T). Prints the
# created window's stable window id on stdout for the caller to target.
#
# Robustness (fm-spawn tmux window handling under a non-default captain config):
#   - Capture a STABLE window id with -P -F '#{window_id}', and let tmux append
#     at the next free index by targeting the session with a trailing colon
#     ("$ses:"), so a non-default base-index (e.g. base-index 1) cannot collide.
#   - PIN the window name by disabling automatic-rename and allow-rename on the
#     new window: the captain's tmux may rename the window away from fm-<id> once
#     treehouse cd's into the worktree, which would break name-based targeting.
# The returned window id lets callers target the window even if its name is ever
# lost, so worktree discovery cannot fall back to the active client's window.
fm_backend_tmux_create_task() {  # <session> <window-name> <proj-abs> -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 wid
  if tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs") || return 1
  tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

# fm_backend_tmux_current_path: the live pane's current working directory, or
# empty on any tmux error. Mirrors fm-spawn.sh's worktree-discovery poll:
# `tmux display-message -p -t "$T" '#{pane_current_path}'`.
fm_backend_tmux_current_path() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

# fm_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for the fixed spawn-time commands
# (`treehouse get`, the GOTMPDIR export) that already ran this exact sequence
# inline in fm-spawn.sh. Mirrors `tmux send-keys -t "$T" "<text>" Enter`.
fm_backend_tmux_send_text_line() {  # <target> <text>
  tmux send-keys -t "$1" "$2" Enter
}

# fm_backend_tmux_send_literal: send TEXT as literal bytes with no
# submission - the caller sends Enter separately (fm-spawn.sh's launch-command
# send pauses between the literal send and Enter for the harness to settle).
# Mirrors `tmux send-keys -t "$T" -l "<text>"`.
fm_backend_tmux_send_literal() {  # <target> <text>
  tmux send-keys -t "$1" -l "$2"
}

# fm_backend_tmux_kill: remove one explicitly named task window, best-effort.
# Empty, omitted, and malformed targets return nonzero before invoking tmux so
# tmux can never interpret an empty target as the caller's current window.
fm_backend_tmux_kill() {  # <target>
  local target=${1:-} session window
  case "$target" in
    *:*)
      session=${target%%:*}
      window=${target#*:}
      ;;
    *) return 1 ;;
  esac
  case "$session:$window" in
    :*|*:|*:*:*) return 1 ;;
  esac
  tmux kill-window -t "=$session:=$window" 2>/dev/null || true
}

# fm_backend_tmux_current_command: <target>'s live foreground process name -
# tmux's own `#{pane_current_command}`, already resolved from the pty's
# foreground process group (verified empirically with real tmux 3.6a: a
# harness invoked interactively stays the reported command even while it
# shells out to subcommands that do not take over the pty - e.g. `bash -c
# "sleep 30"` alone reports "sleep" because bash execs directly into it, but
# a persisting parent script running `sleep` as a child reports the PARENT's
# own name throughout; the value reverts to the shell's own name only once
# the foreground command actually exits). Empty on any tmux error.
fm_backend_tmux_current_command() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# Prove the exact bridge/direct-child relationship from the pane process tree.
# Accepted child surfaces are the direct test/installed `agent` executable and
# Cursor's real exec-a Node form (`comm=node`, argv0=agent, versioned
# cursor-agent index.js). A bridge title without that child, or a generic
# agent/node/Cursor GUI process, is never sufficient.
fm_backend_tmux_cursor_acp_child_alive() {  # <target>
  local pane_pid
  pane_pid=$(tmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null) || return 1
  case "$pane_pid" in ''|*[!0-9]*) return 1 ;; esac
  ps -axo pid=,ppid=,comm=,args= 2>/dev/null | awk -v pane="$pane_pid" '
    function descendant(pid, root, depth) {
      for (depth = 0; depth < 32 && pid != ""; depth++) {
        if (pid == root) return 1
        pid = parent[pid]
      }
      return 0
    }
    function strip_agent_argv0(args) {
      if (args !~ /^(agent|[^[:space:]]*\/agent)[[:space:]]+/) return ""
      sub(/^(agent|[^[:space:]]*\/agent)[[:space:]]+/, "", args)
      return args
    }
    # ps flattens argv, so model word boundaries cannot be recovered here.
    # Require the exact fixed option prefix and terminal acp token, retain at
    # least one nonblank model character, and reject an option-shaped first
    # model token (the bridge itself refuses --prefixed option values).
    function valid_acp_tail(tail, model) {
      if (tail ~ /^--trust[[:space:]]+--force[[:space:]]+acp[[:space:]]*$/) return 1
      if (tail !~ /^--trust[[:space:]]+--force[[:space:]]+--model[[:space:]]+/) return 0
      model = tail
      sub(/^--trust[[:space:]]+--force[[:space:]]+--model[[:space:]]+/, "", model)
      if (model !~ /[[:space:]]+acp[[:space:]]*$/) return 0
      sub(/[[:space:]]+acp[[:space:]]*$/, "", model)
      if (model !~ /[^[:space:]]/) return 0
      if (model ~ /^--[^[:space:]]*([[:space:]]|$)/) return 0
      return 1
    }
    function valid_official_agent(args, path_token) {
      args = strip_agent_argv0(args)
      if (args == "") return 0
      sub(/^--use-system-ca[[:space:]]+/, "", args)
      path_token = args
      sub(/[[:space:]].*$/, "", path_token)
      if (path_token !~ /\/cursor-agent\/versions\/[^\/[:space:]]+\/index\.js$/) return 0
      sub(/^[^[:space:]]+[[:space:]]+/, "", args)
      return valid_acp_tail(args)
    }
    {
      pid = $1
      parent[pid] = $2
      command[pid] = $3
      sub(/^.*\//, "", command[pid])
      $1 = $2 = $3 = ""
      sub(/^[[:space:]]+/, "", $0)
      arguments[pid] = $0
    }
    END {
      for (bridge in command) {
        if (command[bridge] != "fm-cursor-acp" || !descendant(bridge, pane)) continue
        for (child in command) {
          if (parent[child] != bridge) continue
          if (command[child] == "agent") {
            if (valid_acp_tail(strip_agent_argv0(arguments[child]))) {
              found = 1
            }
          }
          if (command[child] == "node" || command[child] == "nodejs") {
            if (valid_official_agent(arguments[child])) {
              found = 1
            }
          }
        }
      }
      exit(found ? 0 : 1)
    }
  '
}

# Cursor-only send identity. Unlike the generic recovery classifier, this never
# treats another recognized harness as sufficient: the pane foreground command
# must be the bridge title and that bridge must own one constrained ACP child.
fm_backend_tmux_cursor_agent_state() {  # <target>
  local target=$1 state comm
  state=$(fm_backend_tmux_agent_state "$target")
  case "$state" in
    missing|unreadable) printf '%s' "$state"; return 0 ;;
  esac
  comm=$(fm_backend_tmux_current_command "$target" 2>/dev/null) || {
    printf 'unreadable'
    return 0
  }
  comm=${comm#-}
  if [ "$comm" = fm-cursor-acp ] && fm_backend_tmux_cursor_acp_child_alive "$target"; then
    printf 'alive'
  elif [ "$state" = dead ]; then
    printf 'dead'
  else
    printf 'ambiguous'
  fi
}

# fm_backend_tmux_agent_state: recovery-grade harness-agent state for one
# recorded target. See bin/fm-backend.sh's fm_backend_agent_state for the
# shared state vocabulary and docs/tmux-backend.md "Agent liveness probe" for
# the empirical basis. Tmux silently falls back to the active window when a
# named target is absent, so the exact recorded window must appear in a
# successful session inventory before its foreground command can be trusted.
# An omitted window or a definitive missing-session/server response is
# `missing`; any other inventory or pane read failure is `unreadable`, so a
# transient tmux problem never licenses a duplicate.
fm_backend_tmux_agent_state() {  # <target>
  local target=$1 comm session window windows inventory_status
  case "$target" in
    *:*:*|'':*|*:'') printf 'unreadable'; return 0 ;;
    *:*) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  session=${target%%:*}
  window=${target#*:}
  if windows=$(LC_ALL=C tmux list-windows -t "$session" -F '#{window_name}' 2>&1); then
    inventory_status=0
  else
    inventory_status=$?
  fi
  if [ "$inventory_status" -ne 0 ]; then
    case "$windows" in
      *"can't find session:"*|*"no server running on "*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
        printf 'missing'
        ;;
      *)
        printf 'unreadable'
        ;;
    esac
    return 0
  fi
  if ! printf '%s\n' "$windows" | grep -Fqx "$window"; then
    printf 'missing'
    return 0
  fi

  comm=$(fm_backend_tmux_current_command "$target") || {
    printf 'unreadable'
    return 0
  }
  comm=${comm#-}
  case "$comm" in
    fm-cursor-acp|agent|node|nodejs)
      if fm_backend_tmux_cursor_acp_child_alive "$target"; then
        printf 'alive'
      else
        printf 'ambiguous'
      fi
      ;;
    *claude*|*codex*|*opencode*|*grok*|*kimi*|pi|pi-signed|pi-launcher|Pi) printf 'alive' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'dead' ;;
    '') printf 'unreadable' ;;
    *) printf 'ambiguous' ;;
  esac
}

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_tmux_agent_alive() {  # <target>
  case "$(fm_backend_tmux_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
