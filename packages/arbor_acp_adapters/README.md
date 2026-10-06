# ArborACP adapters

Optional adapters for Claude Code, Codex, Pi, and ZCode, under `Arbor.ACP.Adapters.*`. This package depends on the generic `arbor_acp` core and `arbor_rpc`; consumers of the native ACP core do not need it.

Version `2.0.0-rc.1` is an unpublished implementation snapshot. Vendor translation, session storage, prompt queues, MCP configuration, tool mapping, and credential/session environment policy belong here. Shared isolation, JSON-RPC validation, and workspace/name validation remain in their owning dependencies.

The planned prerelease is for downstream migration testing. See the
[v1 to v2 migration guide](https://github.com/trust-arbor/arbor_mcp/blob/codex/v2-migration/docs/guides/MIGRATING_V1_TO_V2.md)
for package and namespace changes. Publication is pending; the stable-release
48-hour gate has not passed, and vendor CLI executables remain separate.

Its shared `arbor_rpc` source dependency requires a C17 compiler when installed
on macOS/Darwin or Linux. `CC` selects one compiler executable. Source archives
include C source rather than prebuilt helpers; assembled releases include the
built target helper and need no runtime compiler. Windows native subprocess
operations are unsupported. See the [RPC source-install policy](https://github.com/trust-arbor/arbor_rpc#source-build-and-remaining-gates)
for framing availability and the qualified platform/architecture boundary.

## Installation

Use Elixir `~> 1.17` and reviewed local checkouts while RC1 is unpublished. In a
consumer project next to the ACP workspace and separate ArborRPC repository:

```elixir
defp deps do
  [
    {:arbor_rpc, path: "../arbor_rpc", override: true},
    {:arbor_acp, path: "../arbor_acp/packages/arbor_acp", override: true},
    {:arbor_acp_adapters, path: "../arbor_acp/packages/arbor_acp_adapters"}
  ]
end
```

Adjust paths, then run `mix deps.get`. Both overrides replace unpublished
transitive Hex dependencies. After publication the planned dependency is
`{:arbor_acp_adapters, "~> 2.0.0-rc.1"}`; it is not available from Hex yet.

## First adapted session

Install and authenticate the selected CLI separately. This example uses an
already authenticated Codex CLI on the child PATH and its default model:

```elixir
alias Arbor.ACP.Client

cwd = File.cwd!()
{:ok, client} = Arbor.ACP.start_client(
  transport_mod: Arbor.ACP.AdapterTransport,
  adapter: Arbor.ACP.Adapters.Codex,
  adapter_opts: [cwd: cwd, workspace_roots: [cwd]]
)

try do
  {:ok, %{"sessionId" => session_id}} = Client.new_session(client, cwd)
  {:ok, result} = Client.prompt(client, session_id, "Reply with a short greeting.")
  IO.inspect(result)
after
  case Client.disconnect(client) do
    :ok -> :ok
    {:error, reason} -> IO.warn("ACP cleanup failed: #{inspect(reason)}")
  end
end
```

The default client handler rejects permission requests and file access, and
declines elicitation. A host that supports those operations must provide its own
handler and advertise the corresponding capabilities. Vendor authentication and
network access are prerequisites for this example; the core's
[echo example](https://github.com/trust-arbor/arbor_acp/tree/codex/shared-subprocess/packages/arbor_acp/examples/acp)
is the credential-free starting point.

The [adapter guide](docs/ADAPTER_GUIDE.md) covers executable selection, environment
and authentication, workspace/MCP configuration, per-vendor differences, custom
adapters and troubleshooting. See the [changelog](CHANGELOG.md) for RC changes.
Package tests use captured golden fixtures by default. Live external CLI tests
are explicitly tagged and excluded from ordinary tests.

## Runtime and compatibility

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
qualification limits are documented in the ArborRPC README. Final archive and
supported-platform qualification remain release gates; no Windows backend or
prebuilt helper is promised.

## Standalone documentation

Clone [ArborRPC](https://github.com/trust-arbor/arbor_rpc) separately while the
dependency is unpublished. From the ACP workspace root, run:

```sh
cd packages/arbor_acp_adapters
export ARBOR_RPC_PATH=/absolute/path/to/arbor_rpc
ARBOR_V2_LOCAL=1 MIX_ENV=dev mix deps.get
ARBOR_V2_LOCAL=1 MIX_ENV=dev mix docs --warnings-as-errors
```

`ARBOR_RPC_PATH` selects the independent RPC checkout; `ARBOR_V2_LOCAL=1`
selects the sibling ACP core package.

ExDoc is a dev-only dependency and does not run in consumer applications. Source
links use `arbor_acp_adapters-v<version>` and the `packages/arbor_acp_adapters/` source prefix.
Version tags are created only for a reviewed release; this unpublished prerelease
snapshot does not imply that those prospective tags already exist.

See the [contributor guide](https://github.com/trust-arbor/arbor_acp/blob/codex/shared-subprocess/CONTRIBUTING.md)
for fixture tests, optional real CLI smoke tests and source-archive validation.
