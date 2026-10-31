# Changelog

## Unreleased

- Report every dropped session update through telemetry. Listeners can opt into coalesced drop notices with `notify_update_drops: true`; handlers can implement `handle_session_updates_dropped/3`. Notices respect queue bounds and recover without another update.

- Request handlers may return `{:async, work, state}` to commit state before running cancellable work outside the handler mailbox. Timeouts, cancellation and connection shutdown stop that work and preserve one response per request.

- `WorkspacePath.rm_within/2` still returns `:ok` when a delete is refused or fails, and now logs a warning and emits `[:arbor_acp, :workspace_path, :rm_within, :failed]` with a workspace-relative path (or `"[outside]"`).
- Fix: Codex completions settle only the active turn, and a late start reply cannot reactivate a prompt that has finished.

- **Security / behaviour change:** Claude, Codex and Pi adapters isolate workspace agent config by default (Claude `--setting-sources user` and `--strict-mcp-config`; private homes keyed by ACP session id; Codex minted homes omit `AGENTS.md`, disable skills, and do not trust the project; Pi `--no-context-files` / `--no-approve` and no workspace `.pi` / `AGENTS.md` unless `trust_workspace_config: true`). Existing logins, global settings, models, skills and prompts become invisible; cleanup deletes transcripts and credentials in the generated homes. Keep today's behavior with `trust_workspace_config: true` or an explicit `:claude_config_dir` / `:codex_home` / `:agent_dir`. See the adapters changelog.
- **Contract:** `:handler` MCP callbacks run concurrently and must return the handler state unchanged. A changed state is logged, emitted as `[:arbor_acp, :mcp, :handler, :state_discarded]`, and discarded; the MCP request is still answered. Disconnect does not start a provider callback that has not already entered, and neither does closing the session or cancelling the request.
- **Contract:** A session close is a per-session epoch. A load, resume, or other call that reuses the session, including one that omits `mcpServers` or reserves no id, records the epoch when it starts and may restore the session only if that epoch is unchanged. A call that starts after the close is not failed by it. Calls that started before the close still fail with `mcp_server_id_in_use` and do not reopen the session. The close answers queued MCP requests immediately and stops a module or `:handler` provider that has already entered; a late result is dropped, including from a pid provider that is left running.
- Fix: the ACP client rejected `notice` and context compaction session updates as invalid even when the application had opted in with `clientCapabilities.session.notices` or `.compaction`. It now delivers them, accepting and salvaging them as the ACP SDK 1.9.0 v1 deserializer does (invalid optional values removed, invalid summary items skipped); without the capability it still drops them.
- Fix: MCP-over-ACP notifications are bound to the in-flight request's token. Provider timeouts stop the provider process. Lifecycle calls keep ownership of the server ids they touch. The agent uses the capabilities it sent. Oversized provider results return a visible error. Omitted ACP servers appear on the session result. Empty SDK string ids are accepted.

### Added

- **UNSTABLE:** ArborACP speaks MCP-over-ACP on protocol version 1 (ACP SDK 1.9 v1). An agent that advertises `mcpCapabilities.acp: true` can call MCP methods on a `type: "acp"` server the client provides, and the client can notify the agent while that request is in flight. A server without that advertisement or without a registered provider is left off the session and listed on the result as `omittedMcpServers`. Bridging an Arbor MCP server onto this channel is a follow-up. See `packages/arbor_acp/docs/MCP_OVER_ACP.md`.

## ArborACP / Adapters 1.0.0-rc.4 — 2026-10-26

- **Security:** `Arbor.ACP.Registry` fetch no longer follows HTTP redirects, which re-sent the caller's request headers to the redirect target, even another host or an `http:` URL. A redirect returns `{:error, {:redirect_refused, status, location}}`, with the location's userinfo, query and fragment removed.
- Require `arbor_rpc` 1.0.0-rc.3: subprocess close sends stdin EOF before TERM, and the C compiler is optional.
- Fix an AdapterBridge crash on bare `{:error, reason}` translation results on the session lifecycle path (`session/new`, `session/load`, `session/resume`).
- Docs: how to require RPC's native helper (`config :arbor_rpc, native_helper: :required`) when an application launches agents.

## ArborACP / Adapters 1.0.0-rc.3 — 2026-10-22

- **Security:** resolve symlinks before `..` in `WorkspacePath`, closing a workspace confinement bypass in the client's `fs`/`terminal` authorization and the Codex/ZCode workspace-root checks.
- **Security:** ignore `piCommand` from a project's `.pi/settings.json`, so an untrusted repository cannot choose the executable the Pi adapter spawns; keep the host-supplied cwd as the Pi edit-snapshot root.
- **Security:** require `adapter_opts[:gateway_auth]` and an https/loopback `baseUrl` for Codex gateway authentication.
- Require `arbor_rpc` 1.0.0-rc.2, which ignores relative and empty child `PATH` entries during command lookup.
- Fix an AdapterBridge crash on bare `{:error, reason}` translation results (ZCode `session/list` with an unauthorized cwd).
- Add `Client.initialize_result/1` and `agent_meta/1`.

## ArborACP / Adapters 1.0.0-rc.2 — 2026-10-22

- **Security:** contain Pi edit snapshots to the session workspace and cap their size.
- **Security:** harden Claude, Pi and `npx` argv construction against option injection (the class of CVE-2026-96620).
- Add real-Codex native compatibility CI and authenticated candidate qualification.
- Settle native callbacks scoped to a completed Codex turn even without a separate request-resolution event.
- Add generic ACP extensions and the Codex native API, complete event/server-request access and managed native parameter overrides. Prepare core and adapter RC.2 with the matching minimum core dependency.

- Remove completed working notes, publish the adapter extension contract with core
  docs, and document normal installation of the published RCs.

## ArborACP / Adapters 1.0.0-rc.1 — 2026-10-08

- Correct both extracted packages to independent 1.x versions and use 1.x RPC
  and ACP requirements. Existing 2.0.0-rc.1 releases/tags remain preserved.
- Update package metadata, installed-version checks and release documentation.

## 2.0.0-rc.1 — 2026-10-06

Published initial extraction candidate; the coordinated 2.x version is corrected
by the new 1.x release line.
Stable 1.0.0 promotion remains gated on the unfinished 48-hour qualification.

- Split ACP into the independent `arbor_acp` core and optional
  `arbor_acp_adapters` vendor bundle, under `Arbor.ACP.*`.
- Use shared `Arbor.RPC.*` JSON-RPC, framing and owned subprocess mechanics in
  both protocol libraries. Native helpers provide typed child/group cleanup
  receipts; source installs on macOS/Linux require C17, while assembled releases
  run without a compiler. Windows native subprocess operations are unsupported.
- Fix the private RPC write-publication race by reloading the published payload
  after ownership is claimed, preserving the original deadline, producer checks
  and bounded credit accounting.
- Add the [v1 to v2 migration guide](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/guides/MIGRATING_V1_TO_V2.md).
- Move ArborRPC to its own `trust-arbor/arbor_rpc` repository, with the package at
  its root. Development uses explicit `ARBOR_RPC_PATH`; ACP keeps only the core
  and adapter packages, with unchanged Hex dependency names and module namespaces.
- Add package installation/quickstarts, the ACP and adapter guides, contributor
  commands and troubleshooting. Ship guides in ExDoc and source archives, plus
  the core echo examples in the core archive.
- Use `[:arbor_acp | _]` telemetry names in the v2 implementation; preserve
  `_meta.ex_mcp` wire extensions and existing vendor storage identifiers.

## Historical initial extraction (unreleased)

The entries below describe the earlier ExACP extraction, not the current v2
package names, namespaces or telemetry. See the RC1 entries and package guides
for the current ArborACP surface.

### Added
- Initial extraction of the Agent Client Protocol layer from ExMCP
  (`ExMCP.ACP.*` → `ExACP.*`): client, native agent runtime, adapter bridge,
  and the Claude Code, Codex, Pi, and ZCode adapters.
- `ExACP.Transport` and `ExACP.Transport.Stdio`, so ExACP no longer depends on
  ExMCP's transport layer.
- `ExACP.Telemetry.events/0`, the catalog of emitted telemetry events.
- `ExACP.AdapterEvents` is public, documented API for building the messages a
  custom adapter emits.

### Changed
- The public surface is the documented modules only. Adapter helper modules
  (`ExACP.Adapters.*.Mapper`, `.Config`, `.Protocol`, and similar) and shared
  plumbing (`ExACP.Envelope`, `ExACP.Maps`, `ExACP.Meta`, `ExACP.NameValue`,
  `ExACP.LifecycleParams`, `ExACP.PromptQueue`) are internal.
- **BREAKING (vs. `ExMCP.ACP`):** telemetry events are named `[:ex_acp | _]`
  instead of `[:ex_mcp, :acp | _]`, and the stdio transport's events are
  `[:ex_acp, :transport | _]`. ExMCP 1.x re-emits them under the old names.
