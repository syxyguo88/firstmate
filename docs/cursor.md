# Cursor harness support

Firstmate supports Cursor in two deliberately different modes:

| Role | Cursor surface | Firstmate control path |
| --- | --- | --- |
| Primary Firstmate | Native interactive Cursor CLI | Tracked project hooks plus Cursor-managed background Shell tasks |
| Crewmate, scout, or secondmate | Cursor ACP server | `bin/fm-cursor-acp-bridge.mjs` over JSON-RPC 2.0 stdio |

The split is intentional. Native hooks preserve Cursor's normal interactive
primary experience, while ACP provides a typed session, prompt, cancellation,
permission, and resume contract for supervised workers without parsing a TUI.

## Requirements and launch

Install and authenticate the Cursor CLI so the `agent` executable is on `PATH`.
These commands are useful before launch:

```sh
agent status --format json
agent models
```

Start a Cursor primary from the Firstmate repository root:

```sh
agent
```

`bin/fm-harness.sh` recognizes the official versioned Cursor launcher/process
shape. A generic process named `agent`, an inherited `CURSOR_AGENT` variable, or
a raw launch command beginning with `cursor` is not accepted as verified Cursor
identity by itself.

## Primary integration

`.cursor/hooks.json` registers Cursor's native `sessionStart`, `preToolUse`, and
`stop` events:

- `sessionStart` invokes `bin/fm-sessionstart-nudge.sh --cursor` and returns the
  canonical Firstmate startup instruction as `additional_context`.
- Shell `preToolUse` invokes the watcher-arm and persistent-`cd` seatbelts.
- All `preToolUse` calls pass through the delegation-shape guard. Cursor-native
  `MCP:` tools are exempt from that name-shape classifier.
- `stop` invokes `bin/fm-turnend-guard.sh --cursor`. When supervision is needed
  and unhealthy, the hook returns one typed `FIRSTMATE_OP` follow-up; an
  explicitly aborted Cursor turn is allowed to stop silently.

Cursor can also load Claude-compatible project hooks. The tracked Claude hook
commands therefore suppress themselves whenever a native Cursor payload carries
`cursor_version`, so each event has one Firstmate owner.

`.cursor/skills` links to the shared `.agents/skills` tree. Primary watcher
continuity uses the Cursor protocol in
[`supervision-protocols/cursor.md`](supervision-protocols/cursor.md): run
`bin/fm-watch-arm.sh` as one standalone managed background Shell task, then let
Cursor's managed completion notification wake the session.

## Crewmate and secondmate integration

`bin/fm-spawn.sh` uses shell `exec` to launch a Cursor worker through
`bin/fm-cursor-acp-bridge.mjs`, so bridge exit cannot reveal a shell that might
misinterpret a later prompt as a command. The bridge starts:

```text
agent --trust --force [--model <model>] acp
```

It then performs ACP v1 `initialize`, `authenticate`, and either `session/new`
or `session/load`, followed by `session/prompt`. The bridge:

- publishes semantic busy/idle transitions through `fm-busy-event.sh` with the
  trusted `cursor-acp` source;
- writes the private resume identity to
  `state/<id>.cursor-session.json` with mode `0600`;
- restores that exact session on a later launch instead of guessing from
  Cursor's most-recent session;
- proves session-lock ownership from the constrained versioned Cursor `agent`
  ancestry because ACP tool processes do not inherit `CURSOR_AGENT`; the marker
  alone is never accepted;
- accepts one CR/LF-free prompt per stdin line, which is the Cursor transport
  used by `fm-send.sh`; tmux requires the exact bridge plus its constrained ACP
  child, Herdr correlates its exact foreground bridge PID with the same
  constrained direct-child proof, and other backends require a live endpoint;
- maps `Ctrl-C`/`SIGINT` to ACP `session/cancel` while keeping the bridge alive
  for later prompts;
- treats `/exit`, stdin close, `SIGTERM`, or `SIGHUP` as bounded shutdown paths;
- validates ACP envelopes, session identities, prompt stop reasons, and the
  official nested extension request shapes (including optional question/plan
  labels) before publishing completion.
- retains task metadata and the session sidecar if teardown cannot confirm that
  the worker endpoint has disappeared through an authoritative structured
  backend inventory; an unreadable endpoint is never treated as absent. Orca
  uses successful provider-owned worktree removal as its closure proof.

Permission requests select a real `allow_once` option when Cursor offers one.
An `allow_always` option is never selected automatically. If no `allow_once`
exists, or Cursor asks a blocking question or plan decision, the bridge
rejects/cancels the protocol request and appends a bounded escalation to the
task status stream for Firstmate to handle. It never invents an option.

Use `agent models` against the authenticated account before pinning a model.
Firstmate passes a selected Cursor model through `--model`. Cursor has no
separate verified Firstmate effort axis: any non-default `--effort` for
`harness=cursor` is refused before an endpoint is created.

## Verification

Hermetic Cursor tests use fake processes and a fake ACP server, so they require
no Cursor login or model request. The default test runner also keeps all live
gates skipped unless explicitly opted in.

The no-model live contract gate starts the installed ACP server and performs
only initialize, authentication, and `session/new`:

```sh
FM_CURSOR_CLI_CONTRACT_E2E=1 \
  bash tests/fm-cursor-acp-cli-contract-live-e2e.test.sh
```

The two credentialed model gates are separate and may consume account quota:

```sh
FM_CURSOR_LIVE_E2E=1 \
  bash tests/fm-cursor-primary-live-e2e.test.sh

FM_CURSOR_LIVE_E2E=1 \
  bash tests/fm-cursor-acp-live-e2e.test.sh
```

Both run in private temporary fixtures with absolute timeouts and recursive
descendant cleanup. The primary gate verifies native startup, PreTool denial,
and positive Stop follow-up evidence. The ACP gate limits itself to three
auditable `session/prompt` requests, forces Cursor sandbox mode, rejects
tool-like updates, checks busy/idle and resume behavior, and requires an exact
workspace snapshot after completion.
