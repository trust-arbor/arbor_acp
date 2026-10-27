# Changelog

## Unreleased

- Fix: the AdapterBridge no longer crashes when `translate_outbound/2` answers `session/new`, `session/load` or `session/resume` with `:messages`, `:messages_and_write`, `:pending_and_write` or `:one_shot`. These forms leave the response to the adapter, which answers once the agent has set the session up; `{:ok, :skip, _}` is still answered with the synthesized session. The Pi adapter returns the first two when a setup cancels a running prompt.
- Fix: the AdapterBridge accepts every `translate_outbound/2` result form on the other routes the Pi adapter uses: `session/set_config_option` takes `:messages`, `:one_shot` and a bare `{:error, reason}`; `authenticate` takes `:pending_and_write`, `:messages_and_reply_and_write` and `:one_shot`; and `session/close`, `session/delete`, `session/set_mode`, `session/set_model` and `logout` take `:one_shot`. A contract test drives every form through every such route, with its write accepted and rejected.
- Fix: when the write accompanying a translation fails, the responses among its messages are still delivered: they answer other requests the adapter has already settled, such as prompts it cancelled. The notifications are still dropped with the write, and the request is answered with the write's error.
- **Behaviour change:** the AdapterBridge calls `outbound_write_failed/3` after any failed outbound write, not only `:pending_and_write`, so an adapter can stop tracking a request the bridge answered with the write's error. That includes `initialize` and the `session/list` route of adapters without `list_sessions/2`, whose failed writes previously skipped the callback.
- Fix: `session/list` through `translate_outbound/2` accepts every result form, with the session setups' rules: a write or other form without a result leaves the response to the adapter, and `{:ok, :skip, _}` is answered with an empty list.
- `outbound_write_failed/3` may return `{:write, iodata, state}`. The AdapterBridge writes that small replacement in place of a client response it could not write, such as an error answer on the same native id, so an agent waiting on the answer (often with no timeout) is not left stranded. If the replacement cannot be written either, the native connection is broken and the bridge closes it.
- Fix: when the write for a client's response to an agent request fails, the AdapterBridge returns the error from `send_message/2` instead of pushing an error response under the response's id. Each side numbers its own requests, so that id could belong to one of the client's requests, which the error would then answer.
- **Behaviour change:** the AdapterBridge never answers a `{:ok, :pending, state}` translation itself. `session/set_mode`, `session/set_model`, `session/set_config_option`, `session/close`, `session/delete` and `logout` synthesized a success for it, although the behaviour docs say an adapter-managed `:pending` request is answered later by the adapter.

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
