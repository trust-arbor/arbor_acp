# Changelog

## 2.0.0-rc.1 (planned)

Release candidate for downstream migration testing; publication is pending.

- Extract Claude Code, Codex, Pi and ZCode adapters into an optional vendor bundle
  under `Arbor.ACP.Adapters.*`; native ACP core consumers do not need this package.
- Use the generic ACP bridge and shared RPC subprocess handles for managed
  sessions and finite utilities, with explicit ACK, bounded credit and typed
  cleanup. Vendor CLI executables remain separate prerequisites.
- Retain legacy `_meta.ex_mcp` extensions and Pi session storage identifiers.
- Document [v1 to v2 migration](https://github.com/trust-arbor/arbor_mcp/blob/codex/v2-migration/docs/guides/MIGRATING_V1_TO_V2.md).
- Consume the separate ArborRPC checkout through `ARBOR_RPC_PATH`; use
  `ARBOR_V2_LOCAL=1` only for the sibling ACP core during source development.
- Add complete installation/session examples and a packaged
  [adapter guide](docs/ADAPTER_GUIDE.md) covering CLI prerequisites, environment,
  authentication, workspace/MCP policy and vendor differences.
- Honor Claude `read_file.max_bytes` on correlated UTF-8 responses. Invalid
  limits and oversized or malformed contents return control errors without
  truncation; ACP line limits and independent bridge bounds remain unchanged.

Stable promotion remains gated on the unfinished 48-hour qualification; captured
vendor fixtures do not certify live vendor/network behavior.

## 2.0.0-dev

Initial package extraction from ExMCP. Full v2 runtime qualification remains pending.
