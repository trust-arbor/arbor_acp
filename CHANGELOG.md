# Changelog

## 2.0.0-rc.1 (planned)

Release candidate for downstream migration testing; publication is pending.
Stable 2.0.0 promotion remains gated on the unfinished 48-hour qualification.

- Split ACP into the independent `arbor_acp` core and optional
  `arbor_acp_adapters` vendor bundle, under `Arbor.ACP.*`.
- Use shared `Arbor.RPC.*` JSON-RPC, framing and owned subprocess mechanics in
  both protocol libraries. Native helpers provide typed child/group cleanup
  receipts; source installs on macOS/Linux require C17, while assembled releases
  run without a compiler. Windows native subprocess operations are unsupported.
- Fix the private RPC write-publication race by reloading the published payload
  after ownership is claimed, preserving the original deadline, producer checks
  and bounded credit accounting.
- Add the [v1 to v2 migration guide](https://github.com/trust-arbor/arbor_mcp/blob/codex/v2-migration/docs/guides/MIGRATING_V1_TO_V2.md).

## [Unreleased]

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
