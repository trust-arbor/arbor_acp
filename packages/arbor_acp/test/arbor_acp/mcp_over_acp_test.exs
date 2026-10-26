defmodule Arbor.ACP.McpOverAcpTest do
  use ExUnit.Case, async: true

  alias Arbor.ACP.Agent
  alias Arbor.ACP.Agent.Transport.Memory
  alias Arbor.ACP.Client
  alias Arbor.ACP.Types

  defmodule PairAgent do
    @behaviour Arbor.ACP.Agent.Handler

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def handle_new_session(params, _ctx, state) do
      send(state.test_pid, {:new_session, params})
      {:reply, %{"sessionId" => "sess-1"}, state}
    end

    @impl true
    def handle_prompt(_session_id, _prompt, _ctx, state) do
      {:reply, %{"stopReason" => "end_turn"}, state}
    end

    @impl true
    def handle_close_session(session_id, _ctx, state) do
      send(state.test_pid, {:closed, session_id})
      {:reply, %{}, state}
    end

    @impl true
    def handle_mcp_notification(session_id, params, state) do
      send(state.test_pid, {:mcp_note, session_id, params})
      {:ok, state}
    end
  end

  test "exchanges a result, a null result, an inner error, and a notification" do
    ctx = boot()

    params = open!(ctx, [acp("Tools", "tools")])
    assert params["mcpServers"] == [acp("Tools", "tools")]

    task = mcp_task(ctx, "tools/call", request_id: "call-1", params: %{"name" => "echo"})
    assert_receive {:acp_mcp_request, ref, provider_ctx, request}

    assert provider_ctx.session_id == "sess-1"
    assert provider_ctx.server_id == "tools"
    assert provider_ctx.request_id == "call-1"
    assert is_reference(provider_ctx.token)
    assert request["method"] == "tools/call"
    assert request["params"] == %{"name" => "echo"}

    assert :ok =
             Client.mcp_notify(
               provider_ctx.client,
               provider_ctx.server_id,
               provider_ctx.request_id,
               "notifications/progress",
               token: provider_ctx.token,
               params: %{"progress" => 1}
             )

    assert_receive {:mcp_note, "sess-1", note}
    assert note["serverId"] == "tools"
    assert note["requestId"] == "call-1"
    assert note["method"] == "notifications/progress"
    assert note["params"] == %{"progress" => 1}

    reply(ctx, ref, {:ok, %{"ok" => true}})
    assert {:ok, %{"ok" => true}} = Task.await(task)

    assert {:error, :unknown_mcp_request} =
             Client.mcp_notify(ctx.client, "tools", "call-1", "notifications/progress")

    task = mcp_task(ctx, "resources/read", request_id: "call-2")
    assert_receive {:acp_mcp_request, ref, _provider_ctx, _request}
    reply(ctx, ref, {:ok, nil})
    assert {:ok, nil} = Task.await(task)

    task = mcp_task(ctx, "tools/call", request_id: "call-3")
    assert_receive {:acp_mcp_request, ref, _provider_ctx, _request}

    reply(ctx, ref, {:mcp_error, %{"code" => -32_001, "message" => "missing", "data" => nil}})

    assert {:error, {:mcp_error, %{"code" => -32_001, "message" => "missing", "data" => nil}}} =
             Task.await(task)
  end

  test "opens the session without an ACP server that has no provider" do
    ctx = boot()

    params =
      open!(ctx, [
        acp("Tools", "tools"),
        acp("Missing", "missing"),
        Types.stdio_mcp_server("Local", "/bin/echo")
      ])

    assert params["mcpServers"] == [
             acp("Tools", "tools"),
             Types.stdio_mcp_server("Local", "/bin/echo")
           ]

    assert {:error, :unknown_mcp_server} =
             Agent.mcp_request(ctx.agent, "sess-1", "missing", "tools/list")
  end

  test "leaves an ACP server off the session when the agent did not advertise it" do
    ctx = boot(agent_capabilities: Types.agent_capabilities(session_close: true))

    params = open!(ctx, [acp("Tools", "tools"), Types.stdio_mcp_server("Local", "/bin/echo")])

    assert params["mcpServers"] == [Types.stdio_mcp_server("Local", "/bin/echo")]

    assert {:error, {:unsupported_capability, :acp_mcp}} =
             Agent.mcp_request(ctx.agent, "sess-1", "tools", "tools/list")
  end

  test "closing the session finishes an in-flight MCP call" do
    ctx = boot()
    open!(ctx, [acp("Tools", "tools")])

    task = mcp_task(ctx, "tools/list", request_id: "call-1")
    assert_receive {:acp_mcp_request, _ref, _provider_ctx, _request}

    assert {:ok, %{}} = Client.close_session(ctx.client, "sess-1")
    assert_receive {:closed, "sess-1"}
    assert {:error, :session_closed} = Task.await(task)
  end

  defp acp(name, server_id), do: Types.acp_mcp_server(name, server_id)

  defp acp_capabilities do
    Types.agent_capabilities(acp_mcp: true, session_close: true)
  end

  defp boot(opts \\ []) do
    {:ok, peer} = Memory.new_pair()
    parent = self()
    provider = provider_loop(parent)

    {:ok, agent} =
      Agent.start_link(
        handler: PairAgent,
        handler_opts: [test_pid: parent],
        transport: {:memory, peer},
        agent_capabilities: Keyword.get(opts, :agent_capabilities, acp_capabilities())
      )

    {:ok, client} =
      Client.start_link(
        transport_mod: Memory,
        peer: peer,
        role: :client,
        initialize_timeout: 5_000,
        mcp_providers: %{"tools" => provider}
      )

    %{agent: agent, client: client, provider: provider}
  end

  defp open!(ctx, servers) do
    assert {:ok, %{"sessionId" => "sess-1"}} =
             Client.new_session(ctx.client, "/tmp/project", mcp_servers: servers)

    assert_receive {:new_session, params}, 5_000
    params
  end

  defp mcp_task(ctx, method, opts) do
    Task.async(fn -> Agent.mcp_request(ctx.agent, "sess-1", "tools", method, opts) end)
  end

  defp reply(ctx, ref, outcome), do: send(ctx.provider, {:reply, ref, outcome})

  defp provider_loop(parent) do
    spawn_link(fn ->
      provider_loop(parent, nil)
    end)
  end

  defp provider_loop(parent, _acc) do
    receive do
      {:acp_mcp_request, ref, context, params} ->
        send(parent, {:acp_mcp_request, ref, context, params})

        receive do
          {:reply, ^ref, outcome} ->
            send(context.client, {:acp_mcp_provider_result, ref, outcome})
        end

        provider_loop(parent, nil)
    end
  end
end
