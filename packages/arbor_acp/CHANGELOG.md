# Changelog

## 2.0.0-rc.1 (planned)

Release candidate for downstream migration testing; publication is pending.

- Provide the independent `Arbor.ACP.*` client, native agent and generic adapter
  runtime. Vendor integrations move to the optional `arbor_acp_adapters` bundle.
- Use shared RPC ownership for child stdio, bounded writes and typed cleanup
  receipts. Retain legacy wire metadata and storage identifiers.
- Require the corrected RPC write handoff without changing ACP public APIs.
- Document [v1 to v2 migration](https://github.com/trust-arbor/arbor_mcp/blob/codex/v2-migration/docs/guides/MIGRATING_V1_TO_V2.md).
- Consume ArborRPC from its separate repository through an explicit
  `ARBOR_RPC_PATH` during source development; published dependency metadata keeps
  the normal Hex version requirement.
- Add local-checkout installation, a credential-free echo quickstart, and the
  [ACP guide](docs/ACP_GUIDE.md) for client/agent APIs, handlers, configuration and
  troubleshooting. Include the guide and echo examples in source archives.
- Preserve host Logger policy on stdio startup and return known cleanup errors
  from transport close and client disconnect.

Stable promotion remains gated on the unfinished 48-hour qualification.

## 2.0.0-dev

Initial package extraction from ExMCP. Full v2 runtime qualification remains pending.
