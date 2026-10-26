# Changelog

## Unreleased

- Pi: `session/new`, `session/load` and `session/resume` send `new_session`/`switch_session` alone and the rest of the setup requests (`get_state`, the model catalog, thinking levels, commands and, for load, the transcript) only after Pi answers it. Pi does not await one input line before the next and replaces its session asynchronously, so setup requests written in the same batch could describe the previous session: the response could report the old session's id, model, thinking level or transcript. A session change that a Pi extension cancels (`cancelled: true`) now fails the ACP request instead of reporting the session Pi stayed on as the new one. One session setup runs at a time: a `session/new`, `session/load` or `session/resume` sent while another is in progress waits until that one completes or fails, so overlapping setups no longer report each other's session.
- Claude SDK: render Write tool calls that use Claude Code's `path`, `file_text` or `file_content` input aliases as file diffs.
- Claude SDK: report Claude Agent SDK 0.3.310 (was 0.3.238) in the `CLAUDE_AGENT_SDK_VERSION` environment variable the adapter passes to Claude Code, matching the SDK that claude-agent-acp 782e463 ships.
- Codex: `session/load` and `session/resume` of a thread that this connection started and has not closed now succeed before the thread's first prompt. Codex has no rollout for it yet, so the adapter reads the live thread with `thread/read`, and the session keeps the load's authorized `cwd` and requested model. Any other thread, including one closed with `session/close`, still gets Codex's "no rollout found" error: `thread/read` does not subscribe, and attaching an unsubscribed thread would leave its prompts without `turn/completed`.
- Pi: discover the selected model's thinking levels during session setup and after model switches, publish context-window usage from session stats, and forward live session rename events to ACP clients as title updates (a cleared name clears the title). Model-specific levels need Pi 0.81.0 or newer. Pi 0.80.x, which lacks `get_available_thinking_levels`, still works: sessions start normally and offer the static levels.
- Pi: send `set_model` as a correlated request. The adapter refreshes the session's model and thinking levels only after Pi answers it, so the refresh describes the new model, and a rejected switch reports the model Pi kept. Model switches are serialized: Pi can finish overlapping `set_model` requests in either order, so a switch requested while another one (or its refresh) is outstanding waits, and only the latest waiting switch is sent. Model switches also wait while a `session/new`, `session/load` or `session/resume` is pending. Once Pi has replaced the session, or the session is closed, a waiting or outstanding switch is not carried over: it is not sent, and its replies refresh and publish nothing. If Pi rejects the session change, or a Pi extension cancels it (`cancelled: true`), the switch goes ahead for the session that stays active, and the ACP request fails instead of reporting the requested session. A managed change has already replaced the Pi process, so there the waiting switch is dropped either way. A session change whose ACP request ends before Pi answers it (the client's request timeout, a `$/cancel_request`, or the caller going away) is resolved as not taken effect: the request fails with `-32800`, and held model work no longer waits for a reply that a never-resolving `session_before_switch` extension would withhold. It also follows Pi's `thinking_level_changed` events, and a `set_mode` sent while a refresh is outstanding keeps its level.

## 1.0.0-rc.4 — 2026-10-26

- Require `arbor_rpc` 1.0.0-rc.3. Its `Subprocess.close/1` closes a child's stdin and waits `:eof_grace` before signalling it, and its C compiler is optional.
- Docs: ArborRPC releases after `1.0.0-rc.2` install without a C compiler, and adapter starts then fail with `:native_helper_unavailable`. The README and usage rules now say so and recommend `config :arbor_rpc, native_helper: :required`.

## 1.0.0-rc.3 — 2026-10-22

- **Security:** a project's `.pi/settings.json` can no longer choose the executable the Pi adapter spawns. `piCommand` is honored from adapter options (`:cli_path`/`:pi_command`), `PI_ACP_PI_COMMAND`, or the global agent settings only; the project value is ignored. Previously an untrusted repository could run an arbitrary program at `session/new`.
- **Security:** the Pi edit-snapshot workspace root is the host-supplied session `cwd`; the `cwd` the agent reports in `get_state` no longer replaces it, so an agent cannot widen the rc.2 snapshot containment.
- **Security:** Codex and ZCode `:workspace_roots` checks use the shared `WorkspacePath` canonicalizer, which now resolves symlinks before `..` (see the core changelog); `<root>/link/../…` escapes are rejected.
- Fix: ZCode `session/list` returns `{:error, reason, state}` for a relative or unauthorized `cwd` instead of a bare `{:error, reason}`, which crashed the AdapterBridge (#7).

## 1.0.0-rc.2 — 2026-10-22

- **Security:** Pi edit snapshots are taken only for regular files of at most 1 MiB inside the session workspace. An agent-named path (absolute, `..` or a symlink escape) could previously send any readable file's contents to the ACP client as a diff (#5).
- **Security:** reject Claude Code and Pi CLI option values that would be parsed as extra flags, the argument injection behind CVE-2026-96620 (a value such as `--mcp-config …` could start an arbitrary command). `ClaudeSDK.Protocol.command/1` and `Pi.cli_command/1` now return `{:error, {:invalid_option, key, reason}}` for a value starting with `-` or one that is not a string, checked in the exact form it would reach argv. Claude `--resume` and `--session-id` values must be session UUIDs.
- Add pinned real-Codex native CI and opt-in authenticated release qualification with sanitized receipts and verified subprocess cleanup.
- Cancel native callbacks scoped to a completed turn when Codex omits a separate request-resolution event, preserving unrelated requests and suppressing late replies.
- Add the Codex native API: arbitrary methods, complete native events and server-request replies, explicit exclusive/shared ownership modes and managed native parameter overrides. Stop the native handshake when initialization fails.
- Refresh published-RC installation guidance and consolidate current documentation.


## 1.0.0-rc.1 — 2026-10-08

- Document core Client's explicit `prompt_text/4` collection contract and
  truncation reporting for adapted connections.

- Use the core Client entrypoint consistently in adapter launch examples;
  session and prompt APIs remain in ArborACP.
- Ship agent usage rules in Hex archives and ExDoc, with downstream UsageRules
  setup guidance and API-reference validation through the existing docs gate.
- Update lifecycle examples and tests for core ACP tagged status and bounded stop.

- Require ArborRPC `~> 1.0.0-rc.1` and ArborACP `~> 1.0.0-rc.1`.

- Start independent 1.x versioning for this newly extracted package.
- Preserve the published `2.0.0-rc.1` archive and tag; retire the superseded
  candidate after the replacement is published and its installation verified.
- Update installation, migration and release tooling for independent versions.

## 2.0.0-rc.1 — 2026-10-06

Published initial extraction candidate. Its 2.x version was a coordinated
versioning mistake; this new library now starts its independent 1.x line.
The existing release and tag remain available.

- Extract Claude Code, Codex, Pi and ZCode adapters into an optional vendor bundle
  under `Arbor.ACP.Adapters.*`; native ACP core consumers do not need this package.
- Use the generic ACP bridge and shared RPC subprocess handles for managed
  sessions and finite utilities, with explicit ACK, bounded credit and typed
  cleanup. Vendor CLI executables remain separate prerequisites.
- Retain legacy `_meta.ex_mcp` extensions and Pi session storage identifiers.
- Document [v1 to v2 migration](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/guides/MIGRATING_V1_TO_V2.md).
- Consume the separate ArborRPC checkout through `ARBOR_RPC_PATH`; use
  `ARBOR_V2_LOCAL=1` only for the sibling ACP core during source development.
- Add complete installation/session examples and a packaged
  [adapter guide](docs/ADAPTER_GUIDE.md) covering CLI prerequisites, environment,
  authentication, workspace/MCP policy and vendor differences.
- Honor Claude `read_file.max_bytes` on correlated UTF-8 responses. Invalid
  limits and oversized or malformed contents return control errors without
  truncation; ACP line limits and independent bridge bounds remain unchanged.
- Read ZCode model and reasoning choices from current session snapshots while
  preserving legacy catalogs and session isolation. Model, mode and reasoning
  setters now report native rejection instead of acknowledging success before
  the CLI responds; partial settings updates retain the full model catalog.
- Send explicit ZCode prompt model overrides through the current `modelSelection`
  field, preserving supported reasoning choices and validating them before
  sending or queuing. Prompts without overrides use the native session selection.

Stable promotion remains gated on the unfinished 48-hour qualification; captured
vendor fixtures do not certify live vendor/network behavior.

## 2.0.0-dev

Initial package extraction from ExMCP. Full v2 runtime qualification remains pending.
