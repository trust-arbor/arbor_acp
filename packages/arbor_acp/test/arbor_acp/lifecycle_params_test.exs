defmodule Arbor.ACP.LifecycleParamsTest do
  use ExUnit.Case, async: true

  alias Arbor.ACP.LifecycleParams

  describe "pipeline" do
    test "normalizes lifecycle params with mcp servers and additional directories" do
      opts = [
        mcp_servers: [%{"type" => "stdio", "name" => "tools"}],
        additional_directories: ["/tmp/work"]
      ]

      params =
        %{"cwd" => "/tmp/project"}
        |> LifecycleParams.normalize(opts)

      assert params["mcpServers"] == [%{"type" => "stdio", "name" => "tools"}]
      assert params["additionalDirectories"] == ["/tmp/work"]
    end
  end

  describe "validate/2" do
    test "rejects additional directories unless capability is advertised" do
      assert {:error, {:unsupported_capability, :additional_directories}} =
               LifecycleParams.validate([additional_directories: ["/tmp/work"]], %{})
    end

    test "accepts absolute additional directories when advertised" do
      caps = %{"sessionCapabilities" => %{"additionalDirectories" => %{}}}

      assert :ok = LifecycleParams.validate([additional_directories: ["/tmp/work"]], caps)
    end

    test "rejects relative additional directories" do
      caps = %{"sessionCapabilities" => %{"additionalDirectories" => %{}}}

      assert {:error, {:invalid_params, :additional_directories_must_be_absolute_paths}} =
               LifecycleParams.validate([additional_directories: ["relative"]], caps)
    end

    test "accepts official MCP server descriptors without ExMCP metadata" do
      opts = [mcp_servers: [%{"type" => "http", "name" => "docs", "url" => "http://localhost"}]]

      assert :ok = LifecycleParams.validate(opts, %{})
    end

    test "rejects removed native MCP descriptors" do
      opts = [mcp_servers: [%{"type" => "native", "name" => "local", "service" => :docs}]]

      assert {:error, {:invalid_params, :native_mcp_removed}} =
               LifecycleParams.validate(opts, %{})
    end

    test "accepts BEAM MCP descriptors when ExMCP BEAM support is advertised" do
      opts = [mcp_servers: [%{"type" => "beam", "name" => "local", "service" => :docs}]]

      caps = %{
        "mcpCapabilities" => %{
          "_meta" => %{"ex_mcp.mcpCapabilities" => %{"beam" => true}}
        }
      }

      assert :ok = LifecycleParams.validate(opts, caps)
    end

    test "rejects a malformed acp server and accepts a well-formed one" do
      malformed = [mcp_servers: [%{"type" => "acp", "name" => "tools"}]]

      assert {:error, {:invalid_params, :mcp_server}} =
               LifecycleParams.validate(malformed, %{})

      well_formed = [mcp_servers: [%{"type" => "acp", "name" => "tools", "serverId" => "tools"}]]

      assert :ok = LifecycleParams.validate(well_formed, %{})
    end
  end

  describe "select_acp_servers/3" do
    @advertised %{"mcpCapabilities" => %{"acp" => true}}

    test "omits acp servers unless the agent advertised the boolean capability and a provider is configured" do
      servers = [
        %{"type" => "stdio", "name" => "local"},
        %{"type" => "acp", "name" => "tools", "serverId" => "tools"},
        %{type: :acp, name: "docs", server_id: "docs", meta: %{"trace" => "1"}}
      ]

      assert {:ok,
              %{
                servers: [%{"type" => "stdio", "name" => "local"}],
                server_ids: [],
                omitted: omitted
              }} =
               LifecycleParams.select_acp_servers(servers, %{}, ["tools"])

      assert omitted == [
               %{id: "tools", reason: :mcp_acp_not_advertised},
               %{id: "docs", reason: :mcp_acp_not_advertised}
             ]

      assert {:ok, %{server_ids: [], omitted: [%{id: "tools", reason: :mcp_acp_not_advertised}]}} =
               LifecycleParams.select_acp_servers(
                 [%{"type" => "acp", "name" => "tools", "serverId" => "tools"}],
                 %{"mcpCapabilities" => %{"acp" => %{}}},
                 ["tools"]
               )

      assert {:ok, selected} =
               LifecycleParams.select_acp_servers(servers, @advertised, MapSet.new(["docs"]))

      assert selected.servers == [
               %{"type" => "stdio", "name" => "local"},
               %{
                 "type" => "acp",
                 "name" => "docs",
                 "serverId" => "docs",
                 "_meta" => %{"trace" => "1"}
               }
             ]

      assert selected.server_ids == ["docs"]
      assert selected.omitted == [%{id: "tools", reason: :mcp_provider_not_configured}]
    end

    test "rejects a malformed acp server before omission and rejects duplicate kept ids" do
      assert {:error, {:invalid_params, :mcp_server}} =
               LifecycleParams.select_acp_servers(
                 [%{"type" => "acp", "name" => "", "serverId" => "tools"}],
                 %{},
                 []
               )

      assert {:error, {:invalid_params, :duplicate_mcp_server_id}} =
               LifecycleParams.select_acp_servers(
                 [
                   %{"type" => "acp", "name" => "tools", "serverId" => "tools"},
                   %{"type" => "acp", "name" => "again", "serverId" => "tools"}
                 ],
                 @advertised,
                 ["tools"]
               )
    end
  end
end
