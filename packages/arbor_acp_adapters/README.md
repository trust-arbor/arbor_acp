# ArborACP adapters

Optional Claude Code, Codex, Pi and ZCode adapters, under
`Arbor.ACP.Adapters.*`. This package depends on core ACP and RPC.

Version `1.0.0-rc.1` is published for downstream migration testing. The original
`2.0.0-rc.1` candidate is retired, with its archive and tag preserved. Stable
qualification and the continuous 48-hour soak remain incomplete. See the
[ExMCP migration guide](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/guides/MIGRATING_V1_TO_V2.md).

Use Elixir 1.17 or newer with a compatible OTP release. Installing the transitive
RPC source package on macOS/Darwin or Linux requires a C17 compiler. Assembled
releases include the built helper and need no compiler at runtime; Windows native
subprocess operations are unsupported. See the
[RPC source-build policy](https://github.com/trust-arbor/arbor_rpc#source-build-and-remaining-gates).

## Installation

```elixir
{:arbor_acp_adapters, "== 1.0.0-rc.1"}
```

Run `mix deps.get`. The declared core/RPC dependencies resolve normally from Hex.
An explicit prerelease range such as `~> 1.0.0-rc.1` also selects this candidate;
exact pins and a committed lockfile make downstream reports reproducible.

## First adapted session

Install and authenticate the selected CLI separately. This example uses an
already authenticated Codex CLI on the child PATH and its default model:

```elixir
alias Arbor.ACP.Client

cwd = File.cwd!()
{:ok, client} = Arbor.ACP.Client.start_link(
  transport_mod: Arbor.ACP.AdapterTransport,
  adapter: Arbor.ACP.Adapters.Codex,
  adapter_opts: [cwd: cwd, workspace_roots: [cwd]]
)

try do
  {:ok, %{"sessionId" => session_id}} = Client.new_session(client, cwd)
  {:ok, result} = Client.prompt(client, session_id, "Reply with a short greeting.")
  IO.inspect(result)
after
  case Client.stop(client) do
    :ok -> :ok
    {:error, reason} -> IO.warn("ACP cleanup failed: #{inspect(reason)}")
  end
end
```

The default client handler rejects permission requests and file access, and
declines elicitation. A host that supports those operations must provide its own
handler and advertise the corresponding capabilities. Vendor authentication and
network access are prerequisites for this example; the core's
[echo example](https://github.com/trust-arbor/arbor_acp/tree/main/packages/arbor_acp/examples/acp)
is the credential-free starting point.

The [adapter guide](docs/ADAPTER_GUIDE.md) covers executable selection, environment
and authentication, workspace/MCP configuration, per-vendor differences, custom
adapters and troubleshooting. See the [changelog](CHANGELOG.md) for RC changes.
Package tests use captured golden fixtures by default. Live external CLI tests
are explicitly tagged and excluded from ordinary tests.

## AI agent guidance

The package ships [usage rules](usage-rules.md) for adapter selection, vendor
prerequisites, environment/workspace policy and core lifecycle APIs. They are
also an ExDoc guide. Downstream projects with
[UsageRules](https://usage-rules.hexdocs.pm/readme.html) installed as optional
development tooling can add this to their `mix.exs` project configuration:

```elixir
usage_rules: [file: "AGENTS.md", usage_rules: [:arbor_acp, :arbor_acp_adapters]]
```

Then run `mix usage_rules.sync`. Add `:arbor_rpc` when your code uses it directly.
UsageRules 1.2 requires Elixir 1.18 or newer; shipping these rules adds no
dependency and preserves this package's Elixir 1.17 minimum.

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

From the ACP workspace root, resolve published dependencies and build docs:

```sh
cd packages/arbor_acp_adapters
MIX_ENV=dev mix deps.get
MIX_ENV=dev mix docs --warnings-as-errors
```

For local dependency development, `ARBOR_RPC_PATH` selects RPC source and
`ARBOR_V2_LOCAL=1` selects the sibling ACP core package.

ExDoc is a dev-only dependency and does not run in consumer applications. Source
links use `arbor_acp_adapters-v<version>` and the `packages/arbor_acp_adapters/` source prefix.
The published candidate has its owning package tag. Later versions require
reviewed source and a fresh package-qualified tag.

See the [contributor guide](https://github.com/trust-arbor/arbor_acp/blob/main/CONTRIBUTING.md)
for fixture tests, optional real CLI smoke tests and source-archive validation.
