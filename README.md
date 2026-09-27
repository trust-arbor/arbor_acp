# ExACP

Elixir implementation of the [Agent Client Protocol](https://agentclientprotocol.com)
(ACP). Control coding agents over stdio, drive non-native agents (Claude Code,
Codex, Pi, ZCode) through adapters, or build native ACP agents in Elixir.

> **Status: pre-release.** ExACP is being split out of
> [ExMCP](https://github.com/azmaveth/ex_mcp). Until the cutover, the code here
> is regenerated from ExMCP's `lib/ex_mcp/acp/` by
> `scripts/extract_from_ex_mcp.sh`; do not edit generated paths by hand (see the
> script header for which paths those are).

## Installation

```elixir
def deps do
  [{:ex_acp, "~> 0.1"}]
end
```

## Quick start

```elixir
{:ok, client} = ExACP.start_client(command: ["gemini", "--acp"])
{:ok, %{"sessionId" => sid}} = ExACP.Client.new_session(client, "/my/project")
{:ok, %{"stopReason" => _}} = ExACP.Client.prompt(client, sid, "Fix the bug")

# Non-native agents go through an adapter:
{:ok, client} =
  ExACP.Client.start_link(
    transport_mod: ExACP.AdapterTransport,
    adapter: ExACP.Adapters.ClaudeSDK,
    adapter_opts: [model: "sonnet"]
  )

# Native Elixir agents:
{:ok, agent} = ExACP.start_agent(handler: MyApp.AgentHandler)
```

## Migrating from `ExMCP.ACP`

ExMCP 1.x keeps every public `ExMCP.ACP.*` module as a deprecated forwarder to
the matching `ExACP.*` module, so existing code keeps working while the
compiler points at each call site. ExMCP 2.0 removes them. To migrate:

1. Add `{:ex_acp, "~> 0.1"}` to your deps.
2. Rename `ExMCP.ACP` to `ExACP` everywhere (`ExMCP.ACP.Client` →
   `ExACP.Client`, `ExMCP.start_acp_client/1` → `ExACP.start_client/1`).
3. Rename telemetry handlers: `[:ex_mcp, :acp | rest]` → `[:ex_acp | rest]`, and
   for ACP stdio connections `[:ex_mcp, :transport | rest]` →
   `[:ex_acp, :transport | rest]`. See `ExACP.Telemetry` for the full list.
   ExMCP 1.x re-emits the new events under the old names, so this step can
   wait.
4. Move `config :ex_mcp, codex_legacy_auth_methods: ...` to `config :ex_acp`.
   ExACP still reads the `:ex_mcp` key as a fallback during ExMCP 1.x.

Differences that the ExMCP forwarders cannot hide:

- **Structs.** `%ExMCP.ACP.Client{}`, `%ExMCP.ACP.Agent.Transport.Memory{}` and
  friends no longer exist; values are `%ExACP.*{}`. None of these are
  documented data types (they are GenServer, adapter, or transport state), and
  code that names one fails at compile time rather than silently.
- **Module identity.** Values that carry a module name report the `ExACP` one.
  In particular, Codex `:authorize_workspace` / `:authorize_mcp_server`
  callbacks receive `adapter: ExACP.Adapters.Codex` in their context map.
- **Internal modules.** Modules that were always `@moduledoc false` in ExMCP
  (for example `ExMCP.ACP.RequestValidation`) have no forwarder. Twenty helper
  modules that had a moduledoc but were never meant to be public (such as
  `ExMCP.ACP.Maps` and the adapters' `Mapper`/`Config`/`Protocol` modules) are
  hidden in ExMCP 1.x but keep working through hidden forwarders until 2.0.
  They are internal in ExACP as well, so build messages with `ExACP.Protocol`
  and `ExACP.AdapterEvents` instead.

Wire-visible and on-disk identifiers are unchanged, so peers and existing
state keep working: the `_meta.ex_mcp` extension namespace, the
`ex_mcp.mcpCapabilities` meta key, `_ex_mcp.pi/*` extension methods, the
default `clientInfo.name` of `"ex_mcp"`, and the Pi session map at
`~/.ex_mcp/pi/session-map.json`.

## License

MIT
