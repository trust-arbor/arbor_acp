# Changelog

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
