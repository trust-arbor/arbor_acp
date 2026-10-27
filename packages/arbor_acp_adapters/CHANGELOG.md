# Changelog

## Unreleased

- Pi: every Pi request that reads or changes the session now runs as one serialized operation: a session setup (`new_session`/`switch_session`, then its queries), a switch back to the previous session, a model switch (`set_model`, then its refresh) and the `get_session_stats` usage request. The next one is sent only after the previous one has its reply or failed. Pi does not await one input line before the next and finishes session changes and `set_model` asynchronously, so overlapping requests could complete in either order: setup replies could describe the previous session, overlapping setups could report each other's session, and a model switch could land on the wrong session. A queued model switch or usage request is sent only while its session is still the adapter's session. `session/set_model` still answers at once with the optimistic configuration; a waiting switch is replaced by a newer one for the same session.
- Pi: `set_model` is a correlated request, and the adapter refreshes the session's model and thinking levels only after Pi answers it, so the refresh describes the new model and a rejected switch reports the model Pi kept. The adapter follows Pi's `thinking_level_changed` events, and a `set_mode` sent while a refresh is outstanding keeps its level.
- Pi: a session change that Pi rejects, or that a Pi extension cancels (`cancelled: true`), fails the ACP request instead of reporting the requested session, and the adapter keeps serving the previous session, which the client still uses. Unmanaged, the adapter's workspace and settings go back, and Pi is switched back to the previous session's file if the change had already succeeded. Managed, where the setup already replaced the Pi process (a load starts it with `--session <requested file>`), a new process resumes the previous session's file. Model switches waiting behind the setup then go to the previous session.
- Pi: when the ACP request of a running setup ends (the client's request timeout, a `$/cancel_request`, or the caller going away), it fails with `-32800` at once. The adapter assumes no outcome Pi has not reported. Unmanaged, a change Pi has not answered stays in flight; new setups fail at once with "Pi has not answered an earlier session change" rather than wait, and Pi's late answer decides (a late success sends Pi back to the previous session). Managed, the previous session's process is restored at once. If Pi never answers, queued model switches are never sent; their ACP requests were already answered.
- Pi: a prompt never overlaps a session change, so its updates are tagged with the session Pi ran it in. A `session/prompt` (including a slash command) sent while a `session/new`, `session/load` or `session/resume` is waiting or running, or while Pi is switched back after a setup, fails at once with "Pi is changing sessions; send the prompt again once the session change completes". A setup first answers the running prompt, queued prompts and running prompt commands as cancelled, and asks Pi to abort; previously a managed setup dropped them unanswered with the old process.
- Pi: **behaviour change:** `session/close` and `session/delete` of the active session, managed or unmanaged, answer its running prompt, queued prompts and running prompt commands with `stopReason: "cancelled"` instead of dropping them unanswered; an unmanaged Pi is also asked to abort.
- Pi: a managed `session/close` or `session/delete` that ends the Pi process while a setup is running answers that setup's ACP request with an error instead of leaving it to time out; a setup waiting behind it starts next.
- Pi: if Pi cannot switch back to the previous session, the adapter no longer claims that session: prompts and session settings fail with an error until a new setup succeeds.
- Pi: an untracked reply, such as a setup query answered after its setup ended, never changes the session state; an untracked `get_state` reply no longer repoints the session id, session file or thinking level.
- Pi: a `session/new`, `session/load` or `session/resume` that cancels a running prompt no longer crashes the AdapterBridge. It needs the ArborACP AdapterBridge that accepts `:messages` and `:messages_and_write` for session setups (see the core changelog).
- Pi: **behaviour change:** an unmanaged setup waiting behind another operation returns `{:ok, :pending, state}`, like a managed one, instead of `{:ok, :skip, state}`. The bridge answered `:skip` at once with a session id it made up, and the setup was then answered a second time when it ran.
- Pi: after a setup or close answers a running prompt as cancelled, the next prompt waits until Pi settles the aborted turn, and the aborted turn's streamed output, `agent_end` and `agent_settled` answer nothing. Previously, when a Pi extension refused the session change, the old turn's events answered the next prompt with the old turn's text.
- Pi: a setup or close asks Pi to abort only when a prompt is running; prompt commands such as `/session` are answered as cancelled without an `abort`.
- Pi: a slash command whose write to Pi fails, whether a built-in command or a slash prompt forwarded to Pi, is no longer left pending, so a later close or setup cannot answer it a second time.
- Pi: a prompt that Pi refuses starts the next queued prompt at once. Previously the queue waited for an `agent_settled` that never comes.
- Pi: a managed `session/cancel` answers the queued prompts even when the `abort` write fails.
- Pi: implement `outbound_write_failed/3`. When the consumer cannot write a prompt, prompt command, setup or model switch, the adapter stops tracking it (Pi never received it), so it is not answered again.
- Claude SDK, Codex, ZCode and Pi: when a client's answer to an agent request cannot be written, for example an oversized file read, user-input or dialog answer, the agent gets a small replacement on the same id instead: a control error (Claude), a JSON-RPC error (Codex), a denial (ZCode) or a cancel (Pi). Previously the agent waited for the dropped answer with no timeout, the prompt stayed pending, and later prompts queued behind it. A managed Pi writes the cancel itself; when that write fails too, Pi is closed and its exit answers what it had pending, and the client still gets the write error.
- Pi: a managed Pi that cannot be written to while Pi opens a notification or an empty dialog is treated as exited; its auto-cancel returned an error from `translate_inbound/2`, which the managed path did not handle.
- Claude SDK and Pi: `outbound_write_failed/3` retires only what the failed translation itself started, never a request matched by the failed message's id. A client's response to a Claude file read or a Pi extension request can share its id with a prompt already running, and a failed write of that response cleared the prompt, so the next prompt started at once and the old turn's result answered it.
- Claude SDK: implement `outbound_write_failed/3`. A prompt or control request whose write the bridge rejected (for example an oversized prompt while the port stays open) is no longer pending, so the next prompt starts instead of queueing behind a turn Claude never received, a later `result` answers nothing, and a held Auto fallback notice goes out with the next request.
- Codex and ZCode: `outbound_write_failed/3` retires every native request the failed write was to send, not only native-API requests (Codex) or setters (ZCode), and clears a prompt it made active. A late native reply can no longer answer a `session/new`, `session/load`, `session/resume`, `session/list`, `session/fork`, `session/prompt` or `authenticate` request that the bridge already answered with the write error, and the next ZCode prompt is no longer queued behind one ZCode never received.
- Pi: `session/close` and `session/delete` of the current session make the adapter forget it, so an operation still in flight, such as a model-switch refresh, publishes nothing for the closed session.
- Pi: `session/delete` of another session that the session map does not know no longer falls back to deleting the current session's file.
- Claude SDK: render Write tool calls that use Claude Code's `path`, `file_text` or `file_content` input aliases as file diffs.
- Claude SDK: report Claude Agent SDK 0.3.310 (was 0.3.238) in the `CLAUDE_AGENT_SDK_VERSION` environment variable the adapter passes to Claude Code, matching the SDK that claude-agent-acp 782e463 ships.
- Codex: `session/load` and `session/resume` of a thread that this connection started and has not closed now succeed before the thread's first prompt. Codex has no rollout for it yet, so the adapter reads the live thread with `thread/read`, and the session keeps the load's authorized `cwd` and requested model. Any other thread, including one closed with `session/close`, still gets Codex's "no rollout found" error: `thread/read` does not subscribe, and attaching an unsubscribed thread would leave its prompts without `turn/completed`.
- Pi: discover the selected model's thinking levels during session setup and after model switches, publish context-window usage from session stats, and forward live session rename events to ACP clients as title updates (a cleared name clears the title). Model-specific levels need Pi 0.81.0 or newer. Pi 0.80.x, which lacks `get_available_thinking_levels`, still works: sessions start normally and offer the static levels.

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
