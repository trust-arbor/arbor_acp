defmodule Arbor.ACP.Client.McpProvider do
  @moduledoc """
  Behaviour for a module that serves one MCP-over-ACP server.

  UNSTABLE. The client handler runner calls `c:handle_mcp_request/2` while an
  `mcp/message` request is in flight. `context` includes `:client`,
  `:session_id`, `:server_id`, and `:request_id`. `request` is the validated
  `mcp/message` params.

  Return `{:ok, json}`, `{:mcp_error, error_map}`, or `{:error, reason}`.
  The design note is `docs/MCP_OVER_ACP.md`.
  """

  @callback handle_mcp_request(context :: map(), request :: map()) ::
              {:ok, term()} | {:mcp_error, map()} | {:error, term()}
end
