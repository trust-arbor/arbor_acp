defmodule Arbor.ACP.Integration.McpOverAcpSchemaTest do
  @moduledoc """
  Checks ArborACP MCP-over-ACP JSON against the ACP SDK 1.9 v1 zod schemas.

  A live draft-v2 connection is not used. That API speaks protocol version 2,
  and ArborACP speaks protocol version 1. The v1 connection classes do not
  implement MCP-over-ACP. `test/interop/mcp_over_acp_schema.mjs` validates the
  frames this module encodes.

  Run with:

      mix test test/arbor_acp/integration/mcp_over_acp_schema_test.exs --only interop_acp
  """

  use ExUnit.Case, async: false

  alias Arbor.ACP.Protocol
  alias Arbor.ACP.Types

  @moduletag :interop
  @moduletag :interop_acp
  @moduletag :integration

  @interop_dir Path.expand("../../interop", __DIR__)
  @script Path.join(@interop_dir, "mcp_over_acp_schema.mjs")
  @sdk_package Path.join(@interop_dir, "node_modules/@agentclientprotocol/sdk/package.json")

  test "encoded frames match the sdk 1.9 v1 zod schemas" do
    node = System.find_executable("node") || flunk("Node.js is required for the MCP schema check")
    unless File.exists?(@sdk_package), do: flunk("Install the pinned ACP SDK in test/interop")

    payload = %{
      "server" => Types.acp_mcp_server("Tools", "tools", meta: %{"trace" => "t"}),
      "request" =>
        Protocol.encode_mcp_message_request("tools", "req-1", "tools/call",
          params: %{"name" => "echo"},
          meta: %{"trace" => "t"},
          id: 7
        ),
      "notification" =>
        Protocol.encode_mcp_message_notification("tools", "req-1", "notifications/progress",
          params: %{"progress" => 1}
        ),
      "resultNull" => Protocol.encode_mcp_result(7, nil),
      "resultObject" => Protocol.encode_mcp_result(8, %{"tools" => []}),
      "mcpError" =>
        Protocol.encode_mcp_error(9, %{"code" => -32_001, "message" => "missing", "data" => nil}),
      "emptyServer" => Types.acp_mcp_server("", ""),
      "emptyRequest" => Protocol.encode_mcp_message_request("", "", "", id: 11),
      "emptyNotification" => Protocol.encode_mcp_message_notification("", "", "")
    }

    path =
      Path.join(System.tmp_dir!(), "mcp-over-acp-#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(payload))

    try do
      {output, status} =
        System.cmd(node, [@script, path], cd: @interop_dir, stderr_to_stdout: true)

      assert status == 0, output
      assert Jason.decode!(output) == %{"ok" => true}
    after
      File.rm(path)
    end
  end
end
