# Changelog

## 2.0.0-rc.1 (planned)

Release candidate for downstream migration testing; publication is pending.

- Provide the independent `Arbor.ACP.*` client, native agent and generic adapter
  runtime. Vendor integrations move to the optional `arbor_acp_adapters` bundle.
- Use shared RPC ownership for child stdio, bounded writes and typed cleanup
  receipts. Retain legacy wire metadata and storage identifiers.
- Require the corrected RPC write handoff without changing ACP public APIs.
- Document [v1 to v2 migration](https://github.com/trust-arbor/arbor_mcp/blob/codex/v2-migration/docs/guides/MIGRATING_V1_TO_V2.md).

Stable promotion remains gated on the unfinished 48-hour qualification.

## 2.0.0-dev

Initial package extraction from ExMCP. Full v2 runtime qualification remains pending.
