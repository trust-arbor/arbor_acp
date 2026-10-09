# ArborACP

ACP clients, native agents and the generic adapter runtime. Add the optional
`arbor_acp_adapters` package for bundled vendor implementations.

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
{:arbor_acp, "== 1.0.0-rc.1"}
```

Run `mix deps.get`. The declared core/RPC dependencies resolve normally from Hex.
An explicit prerelease range such as `~> 1.0.0-rc.1` also selects this candidate;
exact pins and a committed lockfile make downstream reports reproducible.

## First session

The credential-free example starts a native Elixir echo agent, creates a session,
prints streamed updates, and closes its subprocess. From this package directory:

```sh
export ARBOR_V2_LOCAL=1
mix deps.get
mix compile
mix run examples/acp/controller.exs
```

Expect streamed echo text followed by a prompt result containing
`"stopReason" => "end_turn"`. `ARBOR_V2_LOCAL=1` makes the controller forward
the local dependency settings to the child agent. No vendor CLI, account, or
API key is needed. See the [example notes](examples/acp/README.md).

The [ACP guide](docs/ACP_GUIDE.md) covers native client connections, session
lifecycle, streaming, handlers, content, limits, registry discovery and writing
an agent. For vendor CLIs, use the optional
[adapter package](https://github.com/trust-arbor/arbor_acp/tree/main/packages/arbor_acp_adapters).
See the [changelog](CHANGELOG.md) for the RC changes.

Temporary controllers can use `Arbor.ACP.Client.with_connection/2,3` with finite
startup and cleanup budgets. `Client.prompt/4` returns the unchanged peer result;
`Client.prompt_text/4` explicitly collects bounded streamed text and reports
truncation. See the [client guide and RC migration notes](docs/ACP_GUIDE.md).

## AI agent guidance

The package ships [usage rules](usage-rules.md) for supported APIs, sessions,
host handlers, timeouts and lifecycle. They are also an ExDoc guide.
Downstream projects with [UsageRules](https://usage-rules.hexdocs.pm/readme.html)
installed as optional development tooling can add this to their `mix.exs`
project configuration:

```elixir
usage_rules: [file: "AGENTS.md", usage_rules: [:arbor_acp]]
```

Then run `mix usage_rules.sync`. Add `:arbor_acp_adapters` or `:arbor_rpc` when
your project uses them. UsageRules 1.2 requires Elixir 1.18 or newer; shipping
these rules adds no dependency and preserves ArborACP's Elixir 1.17 minimum.

## Runtime and custom adapters

Native agents implement `Arbor.ACP.Agent.Handler` and run with `Arbor.ACP.Agent.run/1`. Controllers start with `Arbor.ACP.Client.start_link/1`. Custom adapters implement `Arbor.ACP.Adapter` and use the generic bridge. Public `Arbor.ACP.AdapterSupport` helpers own name/value validation, workspace authorization, and adapter policy over shared RPC subprocess handles; adapter packages must not call core `Internal` modules.

`Adapter.environment_defaults/1` is an optional callback for vendor-owned environment policy. It accepts unset values (`false`) and is applied after the generic baseline, before `env/1` and explicit caller `:env`. Existing `env/1` output stays unchanged.

Managed adapters identify frame credit with the pure optional `subprocess_receipt/2` callback. The bridge ACKs after bounded output admission. `shutdown/1` supports legacy state and explicit success/error tuples; bridge close exposes known cleanup failures. See the [adapter subprocess contract](https://github.com/trust-arbor/arbor_acp/blob/main/packages/arbor_acp/docs/ADAPTER_EXTENSION_API.md) for exact signatures and migration details.

Native child stdio also uses an owned shared handle. Temporary readers retain child lifetime, and filtered reads preserve the original deadline/cutoff. Direct subscribers use generation-tagged RPC events and explicit ACK. The built-in client keeps its bounded pull handoff; transport close and client disconnect expose known cleanup failures.

`AdapterSupport.Subprocess.capture/4` runs finite utility commands with the same
adapter defaults, `env/1`, caller environment overrides and child PATH/cwd policy
as managed children. It combines stderr by default and returns original bytes
plus exit status. Its defaults are 5 seconds and 1 MiB; timeout, pressure and known
cleanup failures remain explicit. Each capturing caller owns the utility child,
including when a different `:owner` option is supplied. Cleanup uses its separate
finite budget after the read deadline; shared kernel/Port allocation and platform limits
still apply.

See `examples/acp` for a native echo agent and controller, and `test/interop` for the pinned official SDK probes. Legacy wire metadata and storage locations are preserved. Shared subprocess write admission, cleanup receipts and host-owned logging have revision-specific qualification checkpoints. The corrected RPC write handoff retains original deadlines and bounded credits. MCP owns its separate handler runtime/scheduler; broader platform coverage and completion of the final 48-hour stable-release gate remain pending.

## Stdio host logging

The host owns logging policy. Agent stdio connection preserves Logger levels,
handlers, filters and Application settings, including when using default stdio.
Route every diagnostic handler to stderr or another non-protocol sink before
starting applications. A release can use:

```elixir
config :logger, :default_handler, config: [type: :standard_error]
```

Normal logging remains enabled. Standalone Mix tasks and the echo-agent example
explicitly route their own default handler to stderr before starting the agent;
they preserve its levels, filters and formatter. In an already running VM,
`:logger_std_h` requires replacing the host-owned handler to change its `:type`.
`Mix.install/2` may still print dependency/compiler output to stdout; compiled
releases avoid that startup caveat.

`Arbor.ACP.Internal.StdioLoggerConfig.configure/0` remains exported with its legacy
behavior as an explicit host opt-in. It sets `:arbor_acp` `:stdio_mode` and the
VM-global Logger, `:logger` application and OTP primary levels to `:emergency`.
It suppresses unrelated application logs and does not redirect them to stderr.
No transport calls it automatically in this package. The old `:stdio_mode` flag itself has
no automatic logger effect.

## Standalone documentation

From the ACP workspace root, resolve published dependencies and build docs:

```sh
cd packages/arbor_acp
MIX_ENV=dev mix deps.get
MIX_ENV=dev mix docs --warnings-as-errors
```

ExDoc is a dev-only dependency and does not run in consumer applications. Source
links use `arbor_acp-v<version>` and the `packages/arbor_acp/` source prefix.
The published candidate has its owning package tag. Later versions require
reviewed source and a fresh package-qualified tag.

See the [contributor guide](https://github.com/trust-arbor/arbor_acp/blob/main/CONTRIBUTING.md)
for package checks, optional interoperability suites and source-archive validation.
