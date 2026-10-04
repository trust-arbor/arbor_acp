# Arbor ACP adapters

Optional adapters for Claude Code, Codex, Pi, and ZCode, under `ArborACP.Adapters.*`. This package depends on the generic `arbor_acp` core and `arbor_rpc`; consumers of the native ACP core do not need it.

Version `2.0.0-dev` is an unpublished implementation snapshot. Vendor translation, session storage, prompt queues, MCP configuration, tool mapping, and credential/session environment policy belong here. Shared isolation, JSON-RPC validation, and workspace/name validation remain in their owning dependencies.

Example adapter selection: `adapter: ArborACP.Adapters.Codex` with the generic ACP adapter transport/bridge. Vendor CLI executables are separate prerequisites; package tests use captured golden fixtures by default. Live external CLI tests are explicitly tagged and excluded from ordinary tests.

Legacy `_meta.ex_mcp` wire extensions, generated native request IDs, and Pi's session-map location are preserved. Module naming and full v2 runtime qualification remain pending.
