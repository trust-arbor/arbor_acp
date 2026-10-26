# ArborACP workspace

Two independent Mix projects live here:

- [ArborACP](packages/arbor_acp/README.md): client, native agent and generic adapter runtime.
- [ArborACP adapters](packages/arbor_acp_adapters/README.md): optional Claude, Codex, Pi and ZCode implementations.

Both packages are published as `1.0.0-rc.3` for downstream testing. Shared
JSON-RPC, framing, environment and subprocess mechanics are provided by
[ArborRPC](https://github.com/trust-arbor/arbor_rpc), in its own repository.
The original `2.0.0-rc.1` candidates are retired, with their tags and archives
preserved. Stable promotion requires the remaining qualification and 48-hour soak.

## Start here

| Task | Documentation |
| --- | --- |
| Connect to or write an ACP agent | [Core quickstart](packages/arbor_acp/README.md), [ACP guide](packages/arbor_acp/docs/ACP_GUIDE.md) |
| Use a vendor CLI | [Adapter quickstart](packages/arbor_acp_adapters/README.md), [adapter guide](packages/arbor_acp_adapters/docs/ADAPTER_GUIDE.md) |
| Run without vendor credentials | [Echo agent/controller](packages/arbor_acp/examples/acp/README.md) |
| Implement a custom adapter | [Adapter extension contract](packages/arbor_acp/docs/ADAPTER_EXTENSION_API.md) |
| Use the full Codex app-server API | [Codex native guide](packages/arbor_acp_adapters/docs/CODEX_NATIVE_API.md) |
| Contribute or release | [Contributing](CONTRIBUTING.md), [BEAM CI](.github/BEAM_CI.md), [releasing](docs/RELEASING.md) |
| Review changes | [Workspace changelog](CHANGELOG.md), [core changelog](packages/arbor_acp/CHANGELOG.md), [adapter changelog](packages/arbor_acp_adapters/CHANGELOG.md) |

ACP is the controller-to-agent protocol. Use
[ArborMCP](https://github.com/trust-arbor/arbor_mcp) for MCP tools, resources and
prompts. See the [ExMCP migration guide](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/guides/MIGRATING_V1_TO_V2.md)
for package, namespace, configuration and ownership changes.

## Installation and development

Choose only the packages your application uses:

```elixir
{:arbor_acp, "== 1.0.0-rc.3"}
# Add when using a bundled vendor adapter:
{:arbor_acp_adapters, "== 1.0.0-rc.3"}
```

Run `mix deps.get`; ACP and RPC dependencies resolve normally from Hex. Vendor
CLIs are installed and authenticated separately. For source development, clone
the default `main` branch and run package commands inside `packages/arbor_acp`
or `packages/arbor_acp_adapters`. This workspace is not a Mix umbrella.
`ARBOR_RPC_PATH` and `ARBOR_V2_LOCAL` optionally select local dependency source;
see [contributing](CONTRIBUTING.md).

Agents run as subprocesses through RPC's native helper, which RPC builds from C
source with a C17 compiler on macOS/Darwin and Linux; `CC` selects one compiler
executable. RPC `1.0.0-rc.2` fails to install without a compiler. Later RPC
releases warn and install without the helper, and starting an agent then fails
with `:native_helper_unavailable`. Applications that launch agents should set
`config :arbor_rpc, native_helper: :required` so a missing compiler fails the
build instead. Source archives include C source; assembled releases include the
built helper and need no compiler at runtime. Windows native subprocess
operations are unsupported. See the
[RPC source-build contract](https://github.com/trust-arbor/arbor_rpc#source-build-and-remaining-gates).

## Version and release ownership

The two packages have independent versions, changelogs, archives and
`arbor_acp-v<version>` / `arbor_acp_adapters-v<version>` tags in this repository.
RPC and MCP use root `v<version>` tags in their own repositories. Source/API,
registry and final sustained qualification are separate checks; see
[releasing](docs/RELEASING.md). `SOURCE_SNAPSHOT` records original extraction
provenance; use the actual Git commit for current qualification.

Completed implementation and verification notes remain in
[Git history](https://github.com/trust-arbor/arbor_acp/tree/b4fffd275453501b4453b921d0555b2e4cb41c34).

## Reporting issues

Report vulnerabilities through the
[private reporting form](https://github.com/trust-arbor/arbor_acp/security/advisories/new).
Use [GitHub issues](https://github.com/trust-arbor/arbor_acp/issues) for other bugs.
