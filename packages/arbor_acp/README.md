# Arbor.ACP

ACP controller/client, native agent, and generic adapter runtime. This core package depends on `arbor_rpc` and contains no vendor adapter runtime modules. Add the optional `arbor_acp_adapters` package to use built-in Claude, Codex, Pi, or ZCode integrations.

Version `2.0.0-dev` is an unpublished implementation snapshot. The accepted namespace is `Arbor.ACP.*`.

Native agents implement `Arbor.ACP.Agent.Handler` and run with `Arbor.ACP.run_agent/1`. Controllers start with `Arbor.ACP.start_client/1`. Custom adapters implement `Arbor.ACP.Adapter` and use the generic bridge. Public `Arbor.ACP.AdapterSupport` helpers own name/value validation, workspace authorization, and adapter policy over shared RPC subprocess handles; adapter packages must not call core `Internal` modules.

`Adapter.environment_defaults/1` is an optional callback for vendor-owned environment policy. It accepts unset values (`false`) and is applied after the generic baseline, before `env/1` and explicit caller `:env`. Existing `env/1` output stays unchanged.

Managed adapters identify frame credit with the pure optional `subprocess_receipt/2` callback. The bridge ACKs after bounded output admission. `shutdown/1` supports legacy state and explicit success/error tuples; bridge close exposes known cleanup failures. See the workspace's `docs/ADAPTER_EXTENSION_API.md` for exact signatures and migration details.

Native child stdio also uses an owned shared handle. Temporary readers retain child lifetime, and filtered reads preserve the original deadline/cutoff. Direct subscribers use generation-tagged RPC events and explicit ACK. The built-in client keeps its bounded pull handoff; transport close and client disconnect expose known cleanup failures.

`AdapterSupport.Subprocess.capture/4` runs finite utility commands with the same
adapter defaults, `env/1`, caller environment overrides and child PATH/cwd policy
as managed children. It combines stderr by default and returns original bytes
plus exit status. Its defaults are 5 seconds and 1 MiB; timeout, pressure and known
cleanup failures remain explicit. Each capturing caller owns the utility child,
including when a different `:owner` option is supplied. Cleanup uses its separate
finite budget after the read deadline; shared kernel/Port allocation and platform limits
still apply.

See `examples/acp` for a native echo agent and controller, and `test/interop` for the pinned official SDK probes. Legacy wire metadata and storage locations are preserved. Shared subprocess pressure/platform qualification and logging convergence, runtime/scheduler redesign, and full v2 qualification remain release gates.

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
No transport calls it automatically in 2.0. The old `:stdio_mode` flag itself has
no automatic logger effect.
