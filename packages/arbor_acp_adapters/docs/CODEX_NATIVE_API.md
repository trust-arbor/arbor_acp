# Codex native app-server API

Introduced in core and adapter packages `1.0.0-rc.2`. Before that candidate is
published, test from the source checkout with local dependencies.

ArborACP adapters expose Codex's native JSON-RPC protocol as well as its portable
ACP interface. Native methods and fields use the names in the installed Codex
app-server schema. There is no method allowlist: new methods work with the
existing native API when the installed Codex version supports them. Experimental
features still require their initialization capability flags.

## Exclusive native connections

```elixir
alias Arbor.ACP.Adapters.Codex.Native

{:ok, client} = Native.start_link(
  adapter_opts: [
    cwd: "/absolute/project",
    native_initialize_params: %{
      "capabilities" => %{"experimentalApi" => true}
    }
  ],
  handler: MyApp.CodexHandler
)

{:ok, result} = Native.request(client, "thread/read", %{"threadId" => thread_id})
:ok = Native.notify(client, "vendor/notification", %{"futureField" => true})
:ok = Arbor.ACP.Client.stop(client)
```

`Native.start_link/1` waits for native initialization and returns its full error
object on failure, after stopping its owned client. Native connections use the
same owned subprocess, frame bounds, pending-request limit, deadlines and cleanup
as ACP connections. `initialize` and `initialized` remain owned by the adapter;
pass all initialization fields in `native_initialize_params` instead of sending
a second handshake. Native `request/4` returns `{:ok, JSON_value}` or
`{:error, error_object_or_local_reason}`. Native error `code`, `message`, `data`
and unknown fields remain unchanged. A local timeout or write error does not
prove the native operation stopped or undo its side effects.

Exclusive mode rejects ACP `session/*` operations. Use native `thread/*` and
`turn/*` methods, native event subscriptions and native server-request handlers
for the entire conversation. Codex owns its sandbox and approval semantics;
native filesystem/configuration/command calls are outside ACP workspace guards.

## Server-initiated requests

Implement the optional generic ACP client extension callback. For example:

```elixir
defmodule MyApp.CodexHandler do
  @behaviour Arbor.ACP.Client.Handler

  def init(_opts), do: {:ok, %{}}
  def handle_session_update(_session, _update, state), do: {:ok, state}
  def handle_permission_request(_session, _call, _options, state),
    do: {:ok, %{"outcome" => "cancelled"}, state}

  def handle_extension_request(
        "_arbor/codex/request",
        %{"method" => "item/tool/call", "params" => params},
        state
      ) do
    result = MyApp.Tools.execute(params)
    {:ok, result, state}
  end

  def handle_extension_request(_method, _params, state) do
    {:error, %{"code" => -32601, "message" => "Unsupported native request"}, state}
  end
end
```

The outer extension parameters contain `method`, `params`, the original native
`requestId`, and the full decoded native `frame`. Callback results must use the
native method's response schema. Return `{:error, error_map, state}` to send a
complete native error. The runtime translates IDs, replies exactly once, times
out handlers, suppresses late replies and propagates native server-request
resolution as ACP cancellation. Missing handlers return Method not found.

Exclusive mode delegates every native server request, including approval and
permission requests, to this callback. In shared mode the existing ACP approval
and elicitation translations remain active; unmapped requests (dynamic tools,
ChatGPT token refresh, future methods) reach this extension callback. Sensitive
native inputs/results stay in application memory and are not logged by the API.

## Full native event subscriptions

```elixir
:ok = Native.subscribe(client, consumer_pid)

# In consumer_pid:
receive do
  {:acp_extension_notification, "_arbor/codex/event", %{"event" => frame}} ->
    handle_native_frame(frame)
end

:ok = Native.unsubscribe(client, consumer_pid)
```

Every decoded native frame after subscription admission is eligible, including
unmapped/global notifications, raw response frames and server requests. Unknown
fields and omitted fields are preserved. Events before subscription are not
replayed. The original `native_events: :raw` transport option is separate: it
only annotates translated ACP messages and is not a complete event stream.

Subscribers are monitored local processes (at most 32). `max_update_queue` and
`max_update_queue_bytes` bound delivery to each subscriber and the optional
extension-notification handler. An overflowing consumer closes the connection,
settles pending calls and cleans up its subprocess; events are not silently
skipped while the connection stays open. Keep consumers draining their mailbox,
and configure frame/queue limits for large payloads. `subscribe_extensions/3`
can filter generic ACP extension methods; native consumers filter `frame` by
native method, thread or turn as needed.

## Managed ACP sessions with native parameters

Use managed mode to wait for the native handshake while keeping raw access off:

```elixir
{:ok, client} = Native.start_link(
  native_mode: :managed,
  adapter_opts: [cwd: "/absolute/project"]
)

{:ok, %{"sessionId" => session}} = Native.new_session(
  client,
  "/absolute/project",
  native_params: %{"ephemeral" => true}
)

{:ok, reply} = Native.prompt_text(client, session, "Return the answer", native_params: %{
  "outputSchema" => %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "string"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }
})
```

The helpers carry overrides in standard ACP metadata:
`_meta["arbor.acp.codex"]["params"]`. Core ACP `new_session`, `load_session`,
`resume_session`, `prompt` and `prompt_text` also accept `meta:` directly. Other
metadata is retained. Overrides apply to native `thread/start`, `thread/resume`
or `turn/start` and preserve ACP session tracking, streaming and completion.

Overrides must be JSON objects with string keys. Unknown fields pass through.
ACP-owned identity, input, workspace, permissions and replay controls cannot be
replaced: `threadId`, `thread`, `cwd`, `input`, `config`, `approvalPolicy`,
`approvalsReviewer`, `sandbox`, `sandboxPolicy`, `permissions`,
`runtimeWorkspaceRoots`, `selectedCapabilityRoots`, `environments`, `path`,
`excludeTurns`, `initialTurnsPageSize` and `initialTurnsSortDirection`. Use an
exclusive native connection for unrestricted native parameters. Overrides are
trusted application options, not a destination for untrusted agent content.

## Shared access

`Native.start_link(native_mode: :shared, ...)` enables both APIs. Alternatively,
set `native_api: :shared` in `adapter_opts` when starting `Arbor.ACP.Client`.
This is an explicit ownership tradeoff: arbitrary native methods can change
state that ACP caches. Coordinate turns, settings and lifecycle mutations in
application code. In particular, native `turn/start` returns its immediate
acknowledgment; `Client.prompt/4` completes only at the final turn event.

Shared mode is useful for native queries, thread goals or dynamic tools alongside
managed ACP prompting. Merely setting `native_params` does not enable raw calls,
server-request forwarding or subscriptions. Raw access is `:off` by default;
`:exclusive` and `:shared` explicitly enable it. Native frame forwarding occurs
only on opted-in connections.

`max_native_pending_requests` in adapter options (default 1024) bounds raw
request admission and forwarded server requests. Existing setup and managed
requests count toward raw client-request admission. Core
`max_pending_requests`, `pending_request_timeout`, `handler_request_timeout`,
frame bounds and bridge outbox bounds apply independently. Increase these limits
explicitly for workloads that require them.

Generate the exact native schema using your installed CLI:

```sh
codex app-server generate-json-schema --out ./codex-schemas
codex app-server generate-json-schema --experimental --out ./codex-schemas
```

See [OpenAI app-server documentation](https://learn.chatgpt.com/docs/app-server)
and [ACP extensibility](https://agentclientprotocol.com/protocol/v1/extensibility).
