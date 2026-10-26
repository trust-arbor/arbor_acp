# Changelog

## Unreleased

- Fix: `Arbor.ACP.Client` delivers `notice`, `compaction_update` and `compaction_summary_chunk` session updates to the handler and event listener when the application advertised `{}` for `clientCapabilities.session.notices` or `.compaction`. The client validated neither kind, so it rejected these updates as invalid and logged a warning, even after opting in. They are now checked strictly against the ACP SDK 1.9.0 v1 schema. Without the matching capability the client drops them with a warning, because agents must not send them unadvertised. `Arbor.ACP.Types` documents the three update shapes and the client session capabilities.
- Fix: MCP-over-ACP notifications require the in-flight request's `:token`, so a closed session cannot notify a later request that reused its server and request ids. A module or `:handler` provider runs in its own process; `:handler_request_timeout` stops it and later handler work continues. A lifecycle call holds every server id it keeps or releases until it commits or aborts. `mcp_request/5` follows the `agentCapabilities` actually sent, including a `handle_initialize/3` override. An oversized provider result is answered with outer `-32603` `"MCP provider unavailable"`. A successful session result lists omitted ACP servers in `omittedMcpServers` and emits `[:arbor_acp, :mcp, :server, :omitted]`. Empty `name`, `serverId`, `requestId`, and `method` strings are accepted, matching the SDK schema.

### Added

- **UNSTABLE:** MCP-over-ACP on protocol version 1 (ACP SDK 1.9 v1). `Arbor.ACP.Agent.mcp_request/5` calls a `type: "acp"` server declared on the session. `Arbor.ACP.Client` registers a provider per server id, answers `mcp/message`, and `mcp_notify/5` sends notifications while that request is in flight. The client includes the server only when the agent advertised `mcpCapabilities.acp == true` and a provider is registered; otherwise the entry is omitted, listed on the session result as `omittedMcpServers`, and the session still opens. See [MCP-over-ACP](docs/MCP_OVER_ACP.md). Serving an Arbor MCP server through a provider is a follow-up.

## 1.0.0-rc.4 — 2026-10-26

- Require `arbor_rpc` 1.0.0-rc.3. Its `Subprocess.close/1` closes a child's stdin and waits `:eof_grace` before signalling it, and its C compiler is optional.
- **Security:** `Arbor.ACP.Registry` fetch no longer lets `:httpc` autoredirect. Cross-origin (and any other) 3xx hops are refused so Authorization and other request headers are not replayed onto a different origin, including an https-to-http downgrade. The refused location is returned without its userinfo, query or fragment.
- Fix: the AdapterBridge also accepts a bare `{:error, reason}` from `translate_outbound/2` on the session lifecycle path (`session/new`, `session/load`, `session/resume`), replying with a JSON-RPC error instead of crashing (follow-up to #12).
- Docs: ArborRPC releases after `1.0.0-rc.2` install without a C compiler, and starting an agent then fails with `:native_helper_unavailable`. The README, usage rules and guides now say so and recommend `config :arbor_rpc, native_helper: :required` for applications that launch agents.

## 1.0.0-rc.3 — 2026-10-22

- **Security:** `Arbor.ACP.AdapterSupport.WorkspacePath.canonical/1` now resolves symlinks before applying `..`, the way the kernel does. A path such as `<root>/link/../secret` where `link` points outside the workspace previously passed `within?/2` (and therefore the client's `fs/*` and `terminal/create` authorization) while the file actually opened lived outside the root.
- Fix: the AdapterBridge no longer crashes (taking the connection down) when an adapter's `translate_outbound/2` reports a failed check as `{:error, reason}` without its state; such results now produce a JSON-RPC error reply for `initialize`, `session/list` and the generic translation path (#7).
- Add `Arbor.ACP.Client.initialize_result/1` and `agent_meta/1`, exposing the agent's complete initialize result and its `_meta` object. Agents advertise extension capabilities in `_meta`; callers previously had to scrape the handshake to see them (closes the remaining gap from #6).

## 1.0.0-rc.2 — 2026-10-22

- **Security:** validate `Arbor.ACP.Registry.npx_command/1` npm package specifiers and separate them from `npx` flags with `--`, so a registry entry cannot inject `npx` options. An invalid specifier returns `{:error, :invalid_npx_package}`.
- Add generic, bidirectional ACP extension requests/notifications, optional handler callbacks, bounded monitored subscriptions and standard session/prompt metadata.
- Refresh published-RC installation guidance and consolidate current documentation.


## 1.0.0-rc.1 — 2026-10-08

- Preserve the peer result unchanged in `Client.prompt/4`. Add explicit
  `prompt_text/4` with a separate result/text envelope, a finite UTF-8 byte cap,
  truncation reporting and same-session overlap admission. Only collecting calls
  retain streamed text; existing callers using synthesized `result["text"]`
  must migrate to the convenience helper.
- Add `Client.with_connection/2,3` with finite startup/cleanup budgets,
  pre-work process registration, caller-death cleanup and retained callback
  outcomes when cleanup fails.
- Correct public protocol types to describe string-keyed JSON objects and give
  builders named return types; document typespec limitations for literal binary keys.

- Document Client/Agent as canonical entrypoints; root startup remains shorthand.
  Add Agent.stop/3 with a reason and finite timeout, preserving options-only stop.
- Ship agent usage rules in Hex archives and ExDoc, with downstream UsageRules
  setup guidance and API-reference validation through the existing docs gate.
- Return tagged operational Client/Agent status, with explicit `status!`
  variants. Add setter timeout options (30-second caller default); caller
  timeout and unavailable client become stable error tuples.
- Add `Client.stop/1,2,3` with one finite caller budget for cleanup and process
  termination. Preserve cleanup errors; disconnect retains the client process.
  Agent stop also accepts a finite timeout. Document linked startup and queued
  cancellation semantics.

- Require ArborRPC `~> 1.0.0-rc.1`.

- Start independent 1.x versioning for this newly extracted package.
- Preserve the published `2.0.0-rc.1` archive and tag; retire the superseded
  candidate after the replacement is published and its installation verified.
- Update installation, migration and release tooling for independent versions.

## 2.0.0-rc.1 — 2026-10-06

Published initial extraction candidate. Its 2.x version was a coordinated
versioning mistake; this new library now starts its independent 1.x line.
The existing release and tag remain available.

- Provide the independent `Arbor.ACP.*` client, native agent and generic adapter
  runtime. Vendor integrations move to the optional `arbor_acp_adapters` bundle.
- Use shared RPC ownership for child stdio, bounded writes and typed cleanup
  receipts. Retain legacy wire metadata and storage identifiers.
- Require the corrected RPC write handoff without changing ACP public APIs.
- Document [v1 to v2 migration](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/guides/MIGRATING_V1_TO_V2.md).
- Consume ArborRPC from its separate repository through an explicit
  `ARBOR_RPC_PATH` during source development; published dependency metadata keeps
  the normal Hex version requirement.
- Add local-checkout installation, a credential-free echo quickstart, and the
  [ACP guide](docs/ACP_GUIDE.md) for client/agent APIs, handlers, configuration and
  troubleshooting. Include the guide and echo examples in source archives.
- Preserve host Logger policy on stdio startup and return known cleanup errors
  from transport close and client disconnect.
- Let adapters defer setter responses until the native agent acknowledges them,
  with explicit write-failure cleanup for pending correlations. Existing adapter
  return forms keep their response behavior.

Stable promotion remains gated on the unfinished 48-hour qualification.

## 2.0.0-dev

Initial package extraction from ExMCP. Full v2 runtime qualification remains pending.
