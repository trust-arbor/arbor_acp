defmodule Arbor.ACP.Client.McpProvider do
  @moduledoc """
  Behaviour for a module that serves one MCP-over-ACP server.

  UNSTABLE. The client calls `c:handle_mcp_request/2` while an `mcp/message`
  request is in flight. The callback runs in its own process, so a timeout
  can stop it without blocking other handler work. `context` includes
  `:client`, `:session_id`, `:server_id`, `:request_id`, and `:token`. Pass
  `:token` to `Arbor.ACP.Client.mcp_notify/5`. `request` is the validated
  `mcp/message` params.

  Return `{:ok, json}`, `{:mcp_error, error_map}`, or `{:error, reason}`.
  The design note is `docs/MCP_OVER_ACP.md`.
  """

  @callback handle_mcp_request(context :: map(), request :: map()) ::
              {:ok, term()} | {:mcp_error, map()} | {:error, term()}
end
