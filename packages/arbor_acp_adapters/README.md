# Arbor ACP adapters

Optional adapters for Claude Code, Codex, Pi, and ZCode, under `Arbor.ACP.Adapters.*`. This package depends on the generic `arbor_acp` core and `arbor_rpc`; consumers of the native ACP core do not need it.

Version `2.0.0-rc.1` is an unpublished implementation snapshot. Vendor translation, session storage, prompt queues, MCP configuration, tool mapping, and credential/session environment policy belong here. Shared isolation, JSON-RPC validation, and workspace/name validation remain in their owning dependencies.

Its shared `arbor_rpc` source dependency requires a C17 compiler when installed
on macOS/Darwin or Linux. `CC` selects one compiler executable. Source archives
include C source rather than prebuilt helpers; assembled releases include the
built target helper and need no runtime compiler. Windows native subprocess
operations are unsupported. See the [RPC source-install policy](../arbor_rpc/README.md#source-build-and-remaining-gates)
for framing availability and the qualified platform/architecture boundary.

Example adapter selection: `adapter: Arbor.ACP.Adapters.Codex` with the generic ACP adapter transport/bridge. Vendor CLI executables are separate prerequisites; package tests use captured golden fixtures by default. Live external CLI tests are explicitly tagged and excluded from ordinary tests.

Legacy `_meta.ex_mcp` wire extensions, generated native request IDs, and Pi's session-map location are preserved. The accepted module namespace is `Arbor.ACP.Adapters.*`; full v2 runtime qualification remains pending.

Pi's managed sessions use shared owned subprocess handles and explicit frame credit. EOF remainder translation preserves a final native response without LF. Startup banner retention is bounded at 64 lines / 64 KiB by default; pressure and queued write rejection fail pending work explicitly. Known cleanup failures surface through bridge close and prevent session replacement/deletion. Existing captured golden fixtures remain unchanged.

Vendor utility commands also use shared bounded capture. Claude logout defaults
to 5 seconds / 64 KiB and reports nonzero status, pressure, timeout and known
cleanup failures. Pi version and npm update probes each use 800 ms / 64 KiB;
Git worktree discovery uses 1 second / 1 MiB. These optional metadata probes omit
unavailable results on failure. Pi's two probes and Claude worktree discovery
honor caller environment overrides, child PATH and cwd. Successful capture keeps
the original bytes, and every utility child belongs to its capturing caller.
Cleanup can add its own finite budget and actor-call allowance after read expiry.
This package uses the shared source-built native backend. Its retained
cleanup receipts, targeted-group boundary, kernel/Port allocation and platform
qualification limits are documented in the Arbor.RPC README. Final archive and
supported-platform qualification remain release gates; no Windows backend or
prebuilt helper is promised.

## Standalone documentation

From the workspace root, run:

```sh
cd packages/arbor_acp_adapters
ARBOR_V2_LOCAL=1 MIX_ENV=dev mix deps.get
ARBOR_V2_LOCAL=1 MIX_ENV=dev mix docs --warnings-as-errors
```

ExDoc is a dev-only dependency and does not run in consumer applications. Source
links use `arbor_acp_adapters-v<version>` and the `packages/arbor_acp_adapters/` source prefix.
Version tags are created only for a reviewed release; this unpublished development
snapshot does not imply that those prospective tags already exist.
