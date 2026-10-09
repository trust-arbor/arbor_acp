# Changelog

## Unreleased

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
