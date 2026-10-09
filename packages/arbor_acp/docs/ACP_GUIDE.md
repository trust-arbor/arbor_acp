# ArborACP guide

ArborACP implements the Agent Client Protocol between a controller (an editor,
UI, or automation host) and an agent. The controller creates sessions and sends
prompts; the agent streams updates and can request permission, filesystem,
terminal, or user-input operations from the host. ACP uses a stateful initialize
handshake and protocol version `1`. MCP protocol revision settings do not apply.

Start with the [installation and local echo quickstart](../README.md). These
guides describe the published `1.0.0-rc.1` candidate. The original
`2.0.0-rc.1` candidate is retired with its tag and archive preserved.

## Connect to a native ACP agent

The default transport starts an ACP-speaking subprocess. Replace the command
below with an installed agent's ACP entrypoint; a normal interactive CLI is not
necessarily an ACP server.

```elixir
alias Arbor.ACP.Client

{:ok, result} = Client.with_connection([
  command: ["your-acp-agent", "--acp"],
  client_info: %{"name" => "my-controller", "version" => "0.1.0"}
], fn client ->
  {:ok, %{"sessionId" => session_id}} = Client.new_session(client, File.cwd!())
  {:ok, result} = Client.prompt(client, session_id, "Hello")
  result
end)
IO.inspect(result)
```

`Arbor.ACP.Client.start_link/1` completes initialization before returning. A failed launch or
handshake returns an error. `new_session/3` requires an absolute working
directory. A prompt accepts text or a list of content maps and returns the
agent's result, including `stopReason`; updates arrive separately while it runs.
Handle error tuples in an application rather than relying on the quickstart's
pattern matches. `stop/1,2,3` closes owned transport resources, reports cleanup failure and
waits for client termination within one finite caller timeout (default 5 seconds).
`disconnect/1` closes the transport while keeping the client process alive.
Start functions return linked processes; supervise long-lived clients.

For temporary connections, `with_connection/2,3` wraps the callback value after
cleanup. The three-argument form takes `establish_timeout: 30_000` and
`cleanup_timeout: 5_000` by default. Startup shares one cutoff across handler,
transport and negotiation; cleanup has a separate cutoff. A guardian handles
abrupt caller exit. Cleanup failure returns
`{:error, {:cleanup_failed, reason, callback_value}}`; callback exceptions are
raised again after cleanup. An existing registered client is never adopted.
Custom transport `close/1` determines external cleanup; arbitrary unregistered
custom effects are outside the helper's ownership contract.

Agents that do not speak ACP need `Arbor.ACP.AdapterTransport` and an adapter.
The optional vendor bundle supplies Claude Code, Codex, Pi and ZCode adapters;
the core package supplies the generic bridge and `Arbor.ACP.Adapter` behaviour.

## Sessions, capabilities and configuration

Inspect `Client.agent_capabilities/1` and `Client.auth_methods/1` after connecting.
Optional lifecycle methods depend on the capabilities advertised by that agent:

| Operation | Client API | Meaning |
| --- | --- | --- |
| Create | `new_session(client, cwd, opts)` | Start a new session |
| Load | `load_session(client, id, cwd, opts)` | Reopen with transcript replay when supported |
| Resume | `resume_session(client, id, cwd, opts)` | Reopen without replay |
| Fork | `fork_session(client, id, cwd, opts)` | Create an independent session; capability-gated and unstable |
| List | `list_sessions(client, opts)` | Discover sessions and any returned cursor |
| Cancel | `cancel(client, id)` | Request prompt cancellation asynchronously |
| Close | `close_session(client, id, opts)` | Release an active session |
| Delete | `delete_session(client, id, opts)` | Remove session history where supported |

`end_session/2` uses close when advertised, otherwise retains its historical local
telemetry-only behavior. Use `disconnect/1` to end the connection. Closing a
session and deleting its saved history are different operations.

Use `authenticate/3` with an advertised method ID or a method-specific params
map. `logout/2` requires the logout capability. Available models, modes and
configuration selectors come from session responses and updates; do not assume
every agent supports the same values. Apply them with `set_mode/3`,
`set_model/3`, or `set_config_option/4`. Each accepts a final keyword list
(`set_mode/4`, `set_model/4`, `set_config_option/5`) with a caller `:timeout`,
defaulting to 30 seconds. Caller expiry returns `{:error, :timeout}` without
confirming remote cancellation or extending the pending-request lifetime.
`Client.status/1,2` and `Agent.status/1,2` return `{:ok, status}` or an error;
use their `status!` variants for explicit value-or-raise inspection.
Cancellation returns `:ok` when queued, without confirming remote action.

Boolean configuration controls require an explicit UI capability:

```elixir
capabilities = Arbor.ACP.Capabilities.put(%{}, :boolean_config_options, true)
# Pass capabilities: capabilities to Client.start_link/1 only if the UI supports them.
```

## Streaming and host handlers

Pass `event_listener: listener_pid` to receive
`{:acp_session_update, session_id, update}` messages. The `update` map contains
the `"sessionUpdate"` discriminator. Common values include
`agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`,
`plan`, `available_commands_update`, `config_option_update`,
`current_mode_update`, `session_info_update`, and `usage_update`.

`Client.prompt/4` blocks its caller while updates continue to arrive. Put the
prompt call in an application-owned task if the same UI process must receive
updates immediately, or handle updates in a client handler. Do not leave a
listener mailbox undrained: delivery is bounded and excess updates are dropped.

For synchronous text collection, call `Client.prompt_text/4` instead:

```elixir
{:ok, %{result: peer_result, text: text, truncated?: truncated?}} =
  Client.prompt_text(client, session_id, "Summarize the project", max_text_bytes: 65_536)
IO.inspect({peer_result["stopReason"], text, truncated?})
```

The peer result is preserved, including extensions. Collected text is a UTF-8
prefix of `agent_message_chunk` text blocks, bounded by the client's
`max_prompt_text_bytes` and any smaller per-call limit. It excludes thoughts,
nontext blocks and inline peer extension text. Check `truncated?`; callbacks
still receive updates independently of the collection cap. A collecting prompt
cannot overlap another prompt in its session; conflicts return
`{:error, :prompt_in_progress}` before sending.

Here is a complete minimal handler that forwards updates and declines permission
requests. It does not grant filesystem or terminal access:

```elixir
defmodule MyApp.ACPHandler do
  @behaviour Arbor.ACP.Client.Handler

  @impl true
  def init(opts), do: {:ok, %{listener: Keyword.fetch!(opts, :listener)}}

  @impl true
  def handle_session_update(session_id, update, state) do
    send(state.listener, {:agent_update, session_id, update})
    {:ok, state}
  end

  @impl true
  def handle_permission_request(_session_id, _tool_call, _options, state) do
    {:ok, %{"outcome" => "cancelled"}, state}
  end
end

# Add these options when starting the client:
# handler: MyApp.ACPHandler, handler_opts: [listener: self()]
```

Implement one session-update callback and one permission callback. Their
context-aware variants, `handle_session_update/4` and
`handle_permission_request/5`, additionally receive the decoded ACP JSON-RPC
message and take precedence when both arities exist. This retains unknown ACP
fields, not arbitrary vendor-native fields. Return a permission outcome whose
selected `optionId` comes from the supplied options, or return `cancelled`.
The runtime owns request correlation and sends the response.

Optional host callbacks cover `handle_file_read/4`, `handle_file_write/4`,
`handle_terminal_request/4`, `handle_form_elicitation/2`,
`handle_url_elicitation/2`, and `handle_elicitation_complete/2`. Advertise only
capabilities your host implements, validate requested paths/operations in that
host, and keep callbacks within the configured timeout. The default handler
rejects permission and file requests and declines form/URL elicitation; terminal
operations are not implemented by it.

When `capabilities` is omitted, the client infers filesystem, terminal and
elicitation capabilities from exported handler callbacks. An explicit
`capabilities` map replaces that inference completely; `%{}` advertises none.
Boolean configuration UI support still requires the explicit opt-in above.

## Content and MCP tools

`Arbor.ACP.Types` constructs JSON-shaped content and update maps:

```elixir
alias Arbor.ACP.Types

prompt = [
  Types.text_block("Summarize this module"),
  Types.resource_block("file:///project/example.ex", text: "defmodule Example do\nend")
]

Types.image_block("image/png", "base64-encoded-image")
Types.audio_block("audio/wav", "base64-encoded-audio")
Types.resource_link_block("file:///project/example.ex", name: "example.ex")
# Send prompt with Client.prompt(client, session_id, prompt).
```

Image, audio, and embedded-content acceptance depends on the agent's advertised
prompt capabilities. Helpers construct data; they do not read files or upload
resources. `Arbor.ACP.AdapterEvents` builds session updates for custom adapters,
including chunks, tool calls, plans and prompt completion responses.

For an agent that supports the requested MCP transports, session options accept
MCP descriptors. This does not install or start an MCP server in the controller:

```elixir
servers = [
  Arbor.ACP.Types.stdio_mcp_server("local-tools", "my-mcp-server", args: ["--stdio"]),
  Arbor.ACP.Types.http_mcp_server("remote-tools", "http://localhost:4000/mcp")
]
# Client.new_session(client, File.cwd!(), mcp_servers: servers)
```

`additional_directories: [...]` requires a non-empty list of absolute paths and
the corresponding session capability. Vendor adapters may impose additional
workspace/MCP authorization. Claude Code configures MCP servers at process launch
instead of from session parameters; consult the adapter guide before forwarding
configuration from a user or remote client.

## Write a native Elixir agent

Implement `Arbor.ACP.Agent.Handler` and run it from a compiled application's stdio
entrypoint. This minimal agent streams a greeting and completes each prompt:

```elixir
defmodule MyApp.HelloAgent do
  @behaviour Arbor.ACP.Agent.Handler

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_new_session(_params, _ctx, state) do
    id = "hello-#{System.unique_integer([:positive])}"
    {:reply, %{"sessionId" => id}, state}
  end

  @impl true
  def handle_prompt(session_id, _prompt, ctx, state) do
    :ok = Arbor.ACP.Agent.agent_message(ctx.agent, session_id, "Hello from the agent")
    {:reply, %{"stopReason" => "end_turn"}, state}
  end
end

# In the agent's stdio entrypoint, after configuring logging:
Arbor.ACP.Agent.run(
  handler: MyApp.HelloAgent,
  agent_info: %{"name" => "hello-agent", "version" => "0.1.0"}
)
```

`Arbor.ACP.Agent.run/1` blocks until the agent exits; `Agent.start_link/1` returns a linked PID
for a host that manages its lifecycle. Optional handler callbacks provide
load/resume/list/fork/close/delete, cancellation, authentication and configuration.
For asynchronous work return `{:noreply, state}` and eventually call
`Arbor.ACP.Agent.finish_prompt/3` with `ctx.prompt_id`; the host must own its
workers, cancellation and shutdown. Agent request helpers cover permissions,
file reads/writes, terminal operations and elicitation when the client supports
them. See `Arbor.ACP.Agent` and `Arbor.ACP.Agent.Handler` for callback contracts.

Keep stdout exclusively for protocol frames. Configure every host Logger handler
to stderr or another sink before starting applications; library startup preserves
host logging policy. See [stdio host logging](https://github.com/trust-arbor/arbor_acp/blob/main/packages/arbor_acp/README.md#stdio-host-logging)
and the complete [echo agent/controller](../examples/acp/README.md).

## Limits, timeouts and troubleshooting

These are client startup options unless specified otherwise:

| Option | Default | Purpose |
| --- | --- | --- |
| `initialize_timeout` | 30,000 ms | Total initialize handshake |
| `max_frame_bytes` | 1 MiB | Inbound/outbound JSON-RPC frame limit |
| `max_pending_requests` | 1,024 | Concurrent requests in either direction |
| `pending_request_timeout` | 30,000 ms | Runtime lifetime of outbound requests |
| `handler_request_timeout` | 30,000 ms | Inbound host callback lifetime |
| `max_prompt_text_bytes` | 1 MiB | Explicitly collected streamed answer per session |
| `max_update_queue` | 32 | Handler/listener queue cutoff |
| `max_update_queue_bytes` | 8 MiB | Aggregate queued update size cutoff |

Most client operations accept a call `timeout` option; prompt calls default to
300,000 ms and lifecycle calls to 30,000 ms. Call timeouts and the runtime's
`pending_request_timeout` are separate bounds: increasing only the caller's wait
does not extend the runtime request lifetime. The native agent has its own frame,
pending-request and callback limits. These limits do not bound all application
memory or the operating system's Port buffers.

| Symptom | Check |
| --- | --- |
| Hex cannot resolve RC1 | Use the explicit `1.0.0-rc.1` prerelease requirement and normal Hex resolution; check the lockfile and registry connectivity |
| Native helper does not compile | Confirm a C17 compiler, target toolchain and `CC`; see the ArborRPC source-build policy |
| Agent exits or initialization fails | Verify executable/arguments, child working directory/environment and that the command speaks ACP |
| Invalid JSON or unexpected stdout | Move startup banners, logs and build output away from the agent's stdout |
| `unsupported_capability` | Inspect the initialized capabilities before using optional lifecycle/content features |
| Files or tools are denied | Supply a host handler and the matching capabilities; defaults intentionally deny access |
| Prompt expires despite a long caller wait | Check the runtime request deadline and host callback deadline as well as `timeout` |
| Missing streamed updates | Drain the listener promptly and inspect queue count/byte cutoffs |
| Close returns an error | Treat cleanup as unconfirmed; retain the error for diagnostics before replacing the session |

## Registry discovery and reference

`Arbor.ACP.Registry.fetch/1` downloads the public agent registry; `parse/1`
accepts already obtained JSON for offline use. `agents/1`, `get_agent/2` and
`find_agents/2` inspect entries, while `distribution/2` and `npx_command/1`
inspect launch metadata. These helpers do not install or run an agent. Review a
distribution before using its command in a subprocess.

The API entrypoints are `Arbor.ACP`, `Arbor.ACP.Client`, `Arbor.ACP.Agent`,
`Arbor.ACP.Client.Handler`, `Arbor.ACP.Agent.Handler`, `Arbor.ACP.Types`,
`Arbor.ACP.Adapter`, `Arbor.ACP.AdapterBridge`, `Arbor.ACP.AdapterTransport`,
and the public `Arbor.ACP.AdapterSupport` helpers. Modules documented as internal
are not extension APIs. See the [changelog](../CHANGELOG.md) and the
[v1 migration guide](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/guides/MIGRATING_V1_TO_V2.md)
for namespace, dependency and host-ownership changes. Legacy `_meta.ex_mcp`
wire metadata remains unchanged in v2.

## Migrating from the original release candidate

The original `arbor_acp 2.0.0-rc.1` client added buffered streamed text to
`Client.prompt/4` results. Independent `1.0.0-rc.1` candidates preserve those
results unchanged. Replace code reading synthesized `result["text"]` with
`Client.prompt_text/4` and read its separate `text` and `truncated?` fields.
A peer's own `"text"` extension stays in `result`; streamed text does not replace it.
Raw prompts no longer allocate a collected-text buffer. Native ACP protocol
version remains 1.

`Arbor.ACP.Types` builders and protocol objects use string keys and string
content discriminators, such as `%{"type" => "text", "text" => "Hello"}`.
Earlier atom-keyed typespecs did not match accepted wire objects. Elixir typespecs
cannot name individual literal binary keys or enumerate literal strings, so
object aliases now describe JSON maps and document the required wire fields.
