# MCP-over-ACP

**UNSTABLE.** This follows the ACP SDK 1.9.0 v1 schema (`McpServerAcp`,
`MessageMcpRequest`, `MessageMcpNotification`, `MessageMcpResponse`,
`McpRequestId`, `McpError`, `mcpCapabilities.acp`). Those shapes are unchanged
since SDK 1.8 and are marked unstable: they are not part of the stable ACP spec
and may change. `mcp/connect`, `mcp/disconnect`, and connection ids were removed
in SDK 1.8 and are not implemented.

The client is the MCP provider. The agent is the MCP consumer. Bridging a real
`arbor_mcp` server onto this channel, so that ordinary MCP tools are served
over ACP, is a follow-up. This note covers the ACP binding only.

## Wire

The client may put `{"type":"acp","name":...,"serverId":...}` in `mcpServers`
on `session/new`, `session/load`, `session/resume`, and `session/fork`.

The agent then sends `mcp/message` **requests**:

```json
{"serverId": "...", "requestId": "...", "method": "tools/list", "params": {}}
```

`params` and `_meta` may be omitted or null. The client answers with a normal
JSON-RPC result whose payload is exactly one inner outcome:

- `{"result": <any JSON, including null>}`
- `{"error": {"code": <int32>, "message": "...", "data": <optional>}}`

If a payload contains both keys, receivers use `result`. An inner MCP error is
still a successful outer ACP response. Outer JSON-RPC errors are reserved for
binding and runtime failures.

The client sends `mcp/message` **notifications** (no `id`) only for a request
that is still in flight. The parameters match the request shape. They carry
progress and subscription updates.

`requestId` is a string chosen by the agent. It is not the outer JSON-RPC id.

## Agent API

`Arbor.ACP.Agent.mcp_request/5` is how a handler calls a method on a server the
client declared for that session:

```elixir
Arbor.ACP.Agent.mcp_request(ctx.agent, session_id, server_id, "tools/list",
  params: %{},
  timeout: 5_000
)
```

`:timeout` is a finite deadline in milliseconds (default 30 seconds). It is
also capped by the agent's `:pending_request_timeout`. The call returns
`{:error, :request_timeout}` when that deadline passes, and the agent sends
`$/cancel_request`.

Results:

- `{:ok, result}` — inner success. `{:ok, nil}` is a JSON null result.
- `{:error, {:mcp_error, map}}` — inner MCP error (`code`, `message`, optional `data`).
- `{:error, reason}` — the request was not sent, or the outer call failed
  (`:unknown_mcp_server`, `:duplicate_request_id`, `:session_closed`,
  `{:unsupported_capability, :acp_mcp}`, a JSON-RPC error map, and the same
  transport errors as `fs/*`).

`:request_id` sets the inner id. The runtime generates one when it is omitted.
`:params` is a string-keyed JSON object or `nil`. `:meta` is optional ACP
`_meta`, not inner MCP metadata.

Provider notifications for an in-flight request are delivered to the optional
agent callback `c:Arbor.ACP.Agent.Handler.handle_mcp_notification/3` as
`{session_id, params, state}`. `params` is the notification object. The
callback returns `{:ok, state}`. A missing callback, or a notification whose
server and request are not in flight, drops the notification. The handler
queue shares the extension queue bounds (`:max_extension_queue`,
`:max_extension_queue_bytes`). A full queue drops the notification and leaves
the request running.

## Client API

An application registers one provider per `serverId` before it puts that id in
a session:

```elixir
:ok = Arbor.ACP.Client.register_mcp_provider(client, "tools", :handler)
:ok = Arbor.ACP.Client.register_mcp_provider(client, "docs", MyApp.Docs)
:ok = Arbor.ACP.Client.register_mcp_provider(client, "live", provider_pid)
```

`start_link/1` accepts the same map as `:mcp_providers`.

- `:handler` calls `c:Arbor.ACP.Client.Handler.handle_mcp_request/4`
  `(session_id, request, context, state)`. The handler module must export it.
- A module exports `handle_mcp_request/2` `(context, request)` and is invoked
  on the client handler runner. See `Arbor.ACP.Client.McpProvider`.
- A pid receives `{:acp_mcp_request, ref, context, request}` and replies with
  `send(context.client, {:acp_mcp_provider_result, ref, outcome})`.

`request` is the validated `mcp/message` params. `context` includes `:client`,
`:session_id`, `:server_id`, and `:request_id`.

Outcomes:

- `{:ok, json}` — encoded as `{"result" => json}`.
- `{:mcp_error, error_map}` — encoded as `{"error" => error_map}` when the map
  is an `McpError`.
- `{:error, reason}` — outer JSON-RPC error, `-32603`.

The handler form also returns the handler state as the last element.

While the request is in flight, the provider sends notifications with
`Arbor.ACP.Client.mcp_notify/5`:

```elixir
Arbor.ACP.Client.mcp_notify(context.client, server_id, request_id, "notifications/progress",
  params: %{"progress" => 1}
)
```

The client sends the notification only when that server and request id are
still active. Otherwise it returns `{:error, :unknown_mcp_request}`.

`unregister_mcp_provider/2` drops a provider that no live or pending session
owns.

## Capability gating

Both directions check the advertisement before any MCP-over-ACP traffic.

The client includes a `type: "acp"` server only when the agent's initialize
result has `mcpCapabilities.acp == true` **and** a provider is registered for
that `serverId`. Otherwise the entry is left out of `mcpServers` and the
session call still succeeds. Stdio, HTTP, and SSE entries are unchanged.
Malformed `type: "acp"` entries (missing `name` or `serverId`) are
`{:error, {:invalid_params, :mcp_server}}`.

The client does not reject a session solely because the caller passed a
`type: "acp"` server with no provider. That refusal is intentionally not
implemented. Omission is logged with a hash of the server id, not the id itself.

The agent accepts `Agent.mcp_request/5` only when its own capabilities include
`mcpCapabilities.acp == true` and that `serverId` was declared on that session.
Anything else returns `{:error, {:unsupported_capability, :acp_mcp}}` or
`{:error, :unknown_mcp_server}` and sends nothing.

## Ownership

A `serverId` belongs to one session on the connection. The provider generates
it and must not reuse it for two ACP MCP servers that are visible at the same
time (SDK requirement).

- Two entries in one `mcpServers` list with the same id are rejected.
- An id reserved for a session that is opening, or bound to another live
  session, is rejected with `{:error, {:invalid_params, :mcp_server_id_in_use}}`.
  The agent answers the same case with JSON-RPC `-32602`.
- `session/load` and `session/resume` may repeat the ids already bound to that
  same session. Ids removed from the new list are released when the call
  succeeds. A failed load leaves the previous binding in place.
- `session/new` and `session/fork` bind ids to the **new** session id. A fork
  cannot reuse an id the source session still holds. The caller supplies new
  ids for the forked session.
- The agent reserves ids before it runs the session handler and releases the
  reservation if that handler fails.

An inner `requestId` is unique per server among **in-flight** requests. The
same id may be reused after the request completes, times out, or is cancelled.
The agent rejects a duplicate locally with `{:error, :duplicate_request_id}`.
The client answers a duplicate on the wire with JSON-RPC `-32600`.

## Bounds, timeouts, cleanup

In-flight `mcp/message` requests count toward the existing
`:max_pending_requests` cap (default 1,024) on each side. A further request
gets `{:error, :too_many_pending_requests}` locally, or JSON-RPC `-32000` when
the peer sent it. There is no separate unbounded table.

The payload limit is the existing `:max_frame_bytes` cap (default 1 MiB) on
the encoded JSON-RPC frame. A larger request or notification returns
`{:error, :frame_too_large}` and is not stored.

The agent deadline is `:timeout`, capped by `:pending_request_timeout` (both
default to 30 seconds). The client bounds the provider callback with
`:handler_request_timeout` and answers a stalled provider with `-32603`.

When a session closes or is deleted, or the close-equivalent `end_session/2`
forgets it:

- the server ids bound to that session are released
- the agent fails in-flight `mcp_request/5` callers with `{:error, :session_closed}`
- the client drops provider work for that session and, if a request is still
  unanswered, sends the JSON-RPC request-cancelled error (`-32800`)

A dead provider process is unregistered. Its in-flight requests receive `-32603`.

## Unknown server or session

`mcp/message` does not carry a session id. The session is the one that owns
`serverId`.

The client answers a request whose server id is not bound to a live session
with an **outer** JSON-RPC error, not an inner `McpError`:

| Situation | Code | Message |
| --- | --- | --- |
| Server id is not bound | `-32602` | Unknown MCP server |
| Server id is bound but that session is gone | `-32602` | Unknown session |
| Params fail schema checks | `-32602` | Invalid request parameters |
| Inner request id is already in flight | `-32600` | Request id is already in use |
| Pending-request cap is full | `-32000` | Too many pending requests |
| Provider is missing or its result is not JSON | `-32603` | MCP provider unavailable, or the handler error |

A notification for an unknown server or a finished request is dropped. It has
no response channel.

## What this does not do

The v1 TypeScript connection classes do not implement MCP-over-ACP. The SDK's
draft-v2 connection API does, and only speaks protocol version 2. ArborACP
speaks protocol 1 and answers a version-2 initialize by negotiating down to 1,
so a live draft-v2 handshake cannot exercise this binding. The wire shapes are
the same in both schemas. Tests check encoded messages against the SDK 1.9.0
v1 `schema.json` zod schemas (`zMcpServerAcp`, `zMessageMcpRequest`,
`zMessageMcpNotification`, `zMessageMcpResponse`, `zMcpError`).

Serving an `Arbor.MCP` server through a provider is left to a later bridge.
The provider callbacks above are the seam that bridge would call.
