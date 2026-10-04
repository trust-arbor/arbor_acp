# Arbor ACP adapters

Optional adapters for Claude Code, Codex, Pi, and ZCode, under `Arbor.ACP.Adapters.*`. This package depends on the generic `arbor_acp` core and `arbor_rpc`; consumers of the native ACP core do not need it.

Version `2.0.0-dev` is an unpublished implementation snapshot. Vendor translation, session storage, prompt queues, MCP configuration, tool mapping, and credential/session environment policy belong here. Shared isolation, JSON-RPC validation, and workspace/name validation remain in their owning dependencies.

Example adapter selection: `adapter: Arbor.ACP.Adapters.Codex` with the generic ACP adapter transport/bridge. Vendor CLI executables are separate prerequisites; package tests use captured golden fixtures by default. Live external CLI tests are explicitly tagged and excluded from ordinary tests.

Legacy `_meta.ex_mcp` wire extensions, generated native request IDs, and Pi's session-map location are preserved. The accepted module namespace is `Arbor.ACP.Adapters.*`; full v2 runtime qualification remains pending.

Pi's managed sessions use shared owned subprocess handles and explicit frame credit. EOF remainder translation preserves a final native response without LF. Startup banner retention is bounded at 64 lines / 64 KiB by default; pressure and queued write rejection fail pending work explicitly. Known cleanup failures surface through bridge close and prevent session replacement/deletion. Existing captured golden fixtures remain unchanged.
