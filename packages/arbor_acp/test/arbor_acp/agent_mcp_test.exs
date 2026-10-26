defmodule Arbor.ACP.AgentMcpTest do
  use ExUnit.Case, async: true

  alias Arbor.ACP.Agent
  alias Arbor.ACP.Agent.Transport.Memory
  alias Arbor.ACP.Protocol
  alias Arbor.ACP.Types

  defmodule McpAgent do
    @behaviour Arbor.ACP.Agent.Handler

    @impl true
    def init(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         fail_close: false,
         advertise_acp: Keyword.get(opts, :advertise_acp)
       }}
    end

    @impl true
    def handle_initialize(_params, _ctx, state) do
      result =
        case state.advertise_acp do
          nil -> %{}
          value -> %{"agentCapabilities" => %{"mcpCapabilities" => %{"acp" => value}}}
        end

      {:reply, result, state}
    end

    @impl true
    def handle_new_session(params, _ctx, state) do
      send(state.test_pid, {:new_session, params})
      state = %{state | fail_close: meta(params, "fail_close") == true}

      cond do
        meta(params, "fail") == true ->
          {:error, :failed, state}

        true ->
          {:reply, %{"sessionId" => meta(params, "sessionId") || "sess-1"}, state}
      end
    end

    @impl true
    def handle_prompt(session_id, prompt, _ctx, state) do
      case prompt do
        [%{"text" => "hold"}] ->
          send(state.test_pid, {:holding, self(), session_id})

          receive do
            :release -> :ok
          end

        _other ->
          send(state.test_pid, {:prompt_ran, session_id})
      end

      {:reply, %{"stopReason" => "end_turn"}, state}
    end

    @impl true
    def handle_load_session(params, _ctx, state) do
      send(state.test_pid, {:load_session, params})
      session_result(params, params["sessionId"], state)
    end

    @impl true
    def handle_resume_session(params, _ctx, state) do
      send(state.test_pid, {:resume_session, params})
      session_result(params, params["sessionId"], state)
    end

    @impl true
    def handle_fork_session(params, _ctx, state) do
      send(state.test_pid, {:fork_session, params})
      session_result(params, meta(params, "sessionId") || "sess-fork", state)
    end

    @impl true
    def handle_close_session(session_id, _ctx, state) do
      send(state.test_pid, {:close_session, session_id})

      if state.fail_close do
        {:error, :failed, state}
      else
        {:reply, %{}, state}
      end
    end

    @impl true
    def handle_delete_session(session_id, _ctx, state) do
      send(state.test_pid, {:delete_session, session_id})
      {:reply, %{}, state}
    end

    @impl true
    def handle_mcp_notification(session_id, params, state) do
      send(state.test_pid, {:mcp_note, session_id, params})
      {:ok, state}
    end

    defp session_result(params, session_id, state) do
      if meta(params, "fail") == true do
        {:error, :failed, state}
      else
        {:reply, %{"sessionId" => session_id}, state}
      end
    end

    defp meta(params, key), do: get_in(params, ["_meta", key])
  end

  test "returns an MCP result, a null result, and an inner error" do
    {agent, transport, _peer} = boot()
    open_session!(transport, 2, [acp("Tools", "tools")])

    assert {:ok, %{"tools" => []}} = call_mcp(agent, transport, "tools/list", %{"tools" => []})
    assert {:ok, nil} = call_mcp(agent, transport, "resources/read", nil)

    assert {:error, {:mcp_error, %{"code" => -32_001, "message" => "missing"}}} =
             call_mcp(agent, transport, "tools/call", :mcp_error)
  end

  test "prefers result when the payload also contains an error" do
    {agent, transport, _peer} = boot()
    open_session!(transport, 2, [acp("Tools", "tools")])

    task = async_mcp(agent, "tools/list")
    request = receive_raw(transport)

    send_json(transport, %{
      "jsonrpc" => "2.0",
      "id" => request["id"],
      "result" => %{
        "result" => %{"ok" => true},
        "error" => %{"code" => 1, "message" => "ignored"}
      }
    })

    assert {:ok, %{"ok" => true}} = Task.await(task)
  end

  test "returns an outer JSON-RPC error and rejects a payload with no outcome" do
    {agent, transport, _peer} = boot()
    open_session!(transport, 2, [acp("Tools", "tools")])

    task = async_mcp(agent, "tools/list")
    request = receive_raw(transport)

    send_raw_message(
      transport,
      Protocol.encode_error(-32_603, "MCP provider unavailable", nil, request["id"])
    )

    assert {:error, %{"code" => -32_603, "message" => "MCP provider unavailable"}} =
             Task.await(task)

    task = async_mcp(agent, "tools/list", request_id: "again")
    request = receive_raw(transport)

    send_json(transport, %{
      "jsonrpc" => "2.0",
      "id" => request["id"],
      "result" => %{"unexpected" => true}
    })

    assert {:error, :invalid_params} = Task.await(task)
  end

  test "sends params and meta and omits nil params" do
    {agent, transport, _peer} = boot()
    open_session!(transport, 2, [acp("Tools", "tools")])

    task =
      async_mcp(agent, "tools/call",
        request_id: "call-1",
        params: %{"name" => "echo"},
        meta: %{"trace" => "t"}
      )

    request = receive_raw(transport)
    assert request["method"] == "mcp/message"
    assert request["params"]["serverId"] == "tools"
    assert request["params"]["requestId"] == "call-1"
    assert request["params"]["method"] == "tools/call"
    assert request["params"]["params"] == %{"name" => "echo"}
    assert request["params"]["_meta"] == %{"trace" => "t"}
    reply_result(transport, request, %{})
    assert {:ok, %{}} = Task.await(task)

    task = async_mcp(agent, "tools/list", request_id: "call-2")
    request = receive_raw(transport)
    refute Map.has_key?(request["params"], "params")
    reply_result(transport, request, %{})
    assert {:ok, %{}} = Task.await(task)
  end

  test "refuses the call when mcpCapabilities.acp is not true and sends nothing" do
    {agent, transport, peer} =
      boot(agent_capabilities: Types.agent_capabilities(load_session: true))

    assert %{"result" => %{"sessionId" => "sess-1"}} =
             open_session(transport, 2, [acp("Tools", "tools")])

    assert {:error, {:unsupported_capability, :acp_mcp}} =
             Agent.mcp_request(agent, "sess-1", "tools", "tools/list")

    refute_outbound(peer)
  end

  test "refuses the call before initialize" do
    {:ok, peer} = Memory.new_pair()

    {:ok, agent} =
      Agent.start_link(
        handler: McpAgent,
        handler_opts: [test_pid: self()],
        transport: {:memory, peer},
        agent_capabilities: acp_capabilities()
      )

    assert {:error, :not_initialized} =
             Agent.mcp_request(agent, "sess-1", "tools", "tools/list")
  end

  test "rejects an unknown server, a duplicate request id, and a full pending cap" do
    {agent, transport, peer} = boot(max_pending_requests: 1)
    open_session!(transport, 2, [acp("Tools", "tools")])

    assert {:error, :unknown_mcp_server} =
             Agent.mcp_request(agent, "sess-1", "other", "tools/list")

    refute_outbound(peer)

    task = async_mcp(agent, "tools/list", request_id: "same")
    _request = receive_raw(transport)

    assert {:error, :duplicate_request_id} =
             Agent.mcp_request(agent, "sess-1", "tools", "tools/list", request_id: "same")

    assert {:error, :too_many_pending_requests} =
             Agent.mcp_request(agent, "sess-1", "tools", "ping", request_id: "other")

    refute_outbound(peer)
    Task.shutdown(task, :brutal_kill)
  end

  test "times out, cancels the outer request, and allows the inner id to be reused" do
    {agent, transport, _peer} = boot(pending_request_timeout: 80)
    open_session!(transport, 2, [acp("Tools", "tools")])

    task = async_mcp(agent, "tools/list", request_id: "slow", timeout: 5_000)
    request = receive_raw(transport)
    cancel = receive_raw(transport)

    assert cancel["method"] == "$/cancel_request"
    assert cancel["params"]["requestId"] == request["id"]
    assert {:error, :request_timeout} = Task.await(task)

    assert {:ok, %{"ok" => true}} =
             call_mcp(agent, transport, "tools/list", %{"ok" => true}, request_id: "slow")
  end

  test "closing the session fails in-flight calls and releases the server id" do
    {agent, transport, _peer} = boot()
    open_session!(transport, 2, [acp("Tools", "tools")], %{"sessionId" => "sess-a"})

    task = async_mcp(agent, "tools/list", session_id: "sess-a")
    request = receive_raw(transport)
    send_raw(transport, 3, "session/close", %{"sessionId" => "sess-a"})

    assert %{"method" => "$/cancel_request"} = receive_raw(transport)
    assert %{"result" => %{}} = receive_raw(transport)
    assert {:error, :session_closed} = Task.await(task)
    assert_receive {:close_session, "sess-a"}

    assert %{"result" => %{"sessionId" => "sess-b"}} =
             open_session(transport, 4, [acp("Tools", "tools")], %{"sessionId" => "sess-b"})

    assert {:ok, nil} =
             call_mcp(agent, transport, "tools/list", nil,
               session_id: "sess-b",
               request_id: request["params"]["requestId"]
             )
  end

  test "a failed close keeps the binding and the in-flight request" do
    {agent, transport, _peer} = boot()

    open_session!(transport, 2, [acp("Tools", "tools")], %{
      "sessionId" => "sess-a",
      "fail_close" => true
    })

    task = async_mcp(agent, "tools/list", session_id: "sess-a", request_id: "kept")
    request = receive_raw(transport)
    send_raw(transport, 3, "session/close", %{"sessionId" => "sess-a"})
    assert %{"error" => %{"code" => -32_603}} = receive_raw(transport)

    reply_result(transport, request, %{"ok" => true})
    assert {:ok, %{"ok" => true}} = Task.await(task)
  end

  test "deleting the session fails in-flight calls and releases the server id" do
    {agent, transport, _peer} = boot()
    open_session!(transport, 2, [acp("Tools", "tools")], %{"sessionId" => "sess-a"})

    task = async_mcp(agent, "tools/list", session_id: "sess-a")
    _request = receive_raw(transport)
    send_raw(transport, 3, "session/delete", %{"sessionId" => "sess-a"})

    assert %{"method" => "$/cancel_request"} = receive_raw(transport)
    assert %{"result" => %{}} = receive_raw(transport)
    assert {:error, :session_closed} = Task.await(task)

    open_session!(transport, 4, [acp("Tools", "tools")], %{"sessionId" => "sess-b"})

    assert {:ok, %{}} =
             call_mcp(agent, transport, "tools/list", %{}, session_id: "sess-b")
  end

  test "rejects a duplicate id, an in-use id, and a malformed acp server" do
    {_agent, transport, _peer} = boot()

    duplicate = open_session(transport, 2, [acp("Tools", "tools"), acp("Other", "tools")])
    assert %{"error" => %{"code" => -32_602, "message" => "Duplicate MCP server id"}} = duplicate
    refute_received {:new_session, _}

    assert %{"result" => %{"sessionId" => "sess-1"}} =
             open_session(transport, 3, [acp("Tools", "tools")])

    assert_receive {:new_session, _}

    in_use = open_session(transport, 4, [acp("Tools", "tools")], %{"sessionId" => "sess-2"})

    assert %{"error" => %{"code" => -32_602, "message" => "MCP server id is already in use"}} =
             in_use

    refute_received {:new_session, _}

    stolen =
      lifecycle(transport, 5, "session/load", %{
        "sessionId" => "sess-2",
        "mcpServers" => [acp("Tools", "tools")]
      })

    assert %{"error" => %{"code" => -32_602, "message" => "MCP server id is already in use"}} =
             stolen

    refute_received {:load_session, _}

    malformed = open_session(transport, 6, [%{"type" => "acp", "name" => "Tools"}])

    assert %{"error" => %{"code" => -32_602, "message" => "Invalid request parameters"}} =
             malformed

    refute_received {:new_session, _}
  end

  test "a handler error releases the reservation so the id can be reused" do
    {agent, transport, _peer} = boot()

    failed = open_session(transport, 2, [acp("Tools", "tools")], %{"fail" => true})
    assert %{"error" => %{"code" => -32_603}} = failed
    assert_receive {:new_session, _}

    open_session!(transport, 3, [acp("Tools", "tools")])
    assert {:ok, nil} = call_mcp(agent, transport, "tools/list", nil)
  end

  test "an empty session id does not keep the reservation" do
    {agent, transport, _peer} = boot()

    response = open_session(transport, 2, [acp("Tools", "tools")], %{"sessionId" => ""})
    assert %{"result" => %{"sessionId" => _}} = response

    open_session!(transport, 3, [acp("Tools", "tools")], %{"sessionId" => "sess-ok"})
    assert {:ok, true} = call_mcp(agent, transport, "ping", true, session_id: "sess-ok")
  end

  test "load replaces the server set and a failed load keeps the previous one" do
    {agent, transport, _peer} = boot()
    open_session!(transport, 2, [acp("A", "a"), acp("B", "b")], %{"sessionId" => "sess-1"})

    task =
      async_mcp(agent, "tools/list", session_id: "sess-1", server_id: "b", request_id: "drop")

    _request = receive_raw(transport)

    send_raw(transport, 3, "session/load", %{
      "sessionId" => "sess-1",
      "cwd" => "/tmp",
      "mcpServers" => [acp("A", "a"), acp("C", "c")]
    })

    assert %{"method" => "$/cancel_request"} = receive_raw(transport)
    assert %{"result" => %{"sessionId" => "sess-1"}} = receive_raw(transport)
    assert {:error, :session_closed} = Task.await(task)
    assert_receive {:load_session, _}

    assert {:error, :unknown_mcp_server} =
             Agent.mcp_request(agent, "sess-1", "b", "tools/list")

    assert {:ok, %{"kept" => true}} =
             call_mcp(agent, transport, "tools/list", %{"kept" => true},
               session_id: "sess-1",
               server_id: "a"
             )

    assert {:ok, %{"added" => true}} =
             call_mcp(agent, transport, "tools/list", %{"added" => true},
               session_id: "sess-1",
               server_id: "c"
             )

    task =
      async_mcp(agent, "tools/list", session_id: "sess-1", server_id: "a", request_id: "stay")

    request = receive_raw(transport)

    failed =
      lifecycle(transport, 4, "session/load", %{
        "sessionId" => "sess-1",
        "mcpServers" => [acp("A", "a"), acp("D", "d")],
        "_meta" => %{"fail" => true}
      })

    assert %{"error" => %{"code" => -32_603}} = failed
    reply_result(transport, request, %{"still" => true})
    assert {:ok, %{"still" => true}} = Task.await(task)

    open_session!(transport, 5, [acp("D", "d")], %{"sessionId" => "sess-d"})

    assert {:ok, true} =
             call_mcp(agent, transport, "ping", true, session_id: "sess-d", server_id: "d")
  end

  test "resume without mcpServers leaves bindings in place" do
    {agent, transport, _peer} = boot()
    open_session!(transport, 2, [acp("A", "a")], %{"sessionId" => "sess-1"})

    resumed =
      lifecycle(transport, 3, "session/resume", %{
        "sessionId" => "sess-1"
      })

    assert %{"result" => %{"sessionId" => "sess-1"}} = resumed
    assert_receive {:resume_session, params}
    refute Map.has_key?(params, "mcpServers")

    assert {:ok, 1} = call_mcp(agent, transport, "ping", 1, session_id: "sess-1", server_id: "a")
  end

  test "fork binds only the ids on the fork and cannot reuse a parent id" do
    {agent, transport, _peer} = boot()
    open_session!(transport, 2, [acp("Parent", "parent")], %{"sessionId" => "sess-parent"})

    stolen =
      lifecycle(transport, 3, "session/fork", %{
        "sessionId" => "sess-parent",
        "mcpServers" => [acp("Parent", "parent")],
        "_meta" => %{"sessionId" => "sess-child"}
      })

    assert %{"error" => %{"code" => -32_602, "message" => "MCP server id is already in use"}} =
             stolen

    refute_received {:fork_session, _}

    forked =
      lifecycle(transport, 4, "session/fork", %{
        "sessionId" => "sess-parent",
        "_meta" => %{"sessionId" => "sess-child"}
      })

    assert %{"result" => %{"sessionId" => "sess-child"}} = forked

    assert {:error, :unknown_mcp_server} =
             Agent.mcp_request(agent, "sess-child", "parent", "tools/list")

    assert {:ok, true} =
             call_mcp(agent, transport, "ping", true,
               session_id: "sess-parent",
               server_id: "parent"
             )

    child =
      lifecycle(transport, 5, "session/fork", %{
        "sessionId" => "sess-parent",
        "mcpServers" => [acp("Child", "child")],
        "_meta" => %{"sessionId" => "sess-child-2"}
      })

    assert %{"result" => %{"sessionId" => "sess-child-2"}} = child

    assert {:ok, "child"} =
             call_mcp(agent, transport, "ping", "child",
               session_id: "sess-child-2",
               server_id: "child"
             )

    assert {:error, :unknown_mcp_server} =
             Agent.mcp_request(agent, "sess-parent", "child", "tools/list")
  end

  test "delivers a notification for an in-flight request and drops any other" do
    {agent, transport, _peer} = boot()
    open_session!(transport, 2, [acp("Tools", "tools")])

    task = async_mcp(agent, "tools/list", request_id: "live")
    request = receive_raw(transport)

    send_raw_message(
      transport,
      Protocol.encode_mcp_message_notification("tools", "live", "notifications/progress",
        params: %{"progress" => 1}
      )
    )

    send_raw_message(
      transport,
      Protocol.encode_mcp_message_notification("tools", "done", "notifications/progress",
        params: %{"progress" => 2}
      )
    )

    reply_result(transport, request, %{})
    assert {:ok, %{}} = Task.await(task)

    assert_receive {:mcp_note, "sess-1",
                    %{"requestId" => "live", "method" => "notifications/progress"}}

    send_raw(transport, 3, "session/prompt", %{
      "sessionId" => "sess-1",
      "prompt" => [%{"type" => "text", "text" => "go"}]
    })

    assert_receive {:prompt_ran, "sess-1"}
    refute_received {:mcp_note, _, _}
    assert %{"result" => %{"stopReason" => "end_turn"}} = receive_raw(transport)
  end

  test "drops an MCP notification when the handler queue is full and stays up" do
    {agent, transport, _peer} = boot(max_extension_queue: 1)
    open_session!(transport, 2, [acp("Tools", "tools")])

    send_raw(transport, 3, "session/prompt", %{
      "sessionId" => "sess-1",
      "prompt" => [%{"type" => "text", "text" => "hold"}]
    })

    assert_receive {:holding, handler, "sess-1"}

    task = async_mcp(agent, "tools/list", request_id: "queued")
    request = receive_raw(transport)

    send_raw_message(
      transport,
      Protocol.encode_mcp_message_notification("tools", "queued", "notifications/progress",
        params: %{"progress" => 1}
      )
    )

    send_raw_message(
      transport,
      Protocol.encode_mcp_message_notification("tools", "queued", "notifications/message",
        params: %{"progress" => 2}
      )
    )

    reply_result(transport, request, %{"ok" => true})
    assert {:ok, %{"ok" => true}} = Task.await(task)

    send(handler, :release)
    assert_receive {:mcp_note, "sess-1", %{"method" => "notifications/progress"}}
    refute_received {:mcp_note, "sess-1", %{"method" => "notifications/message"}}
    assert %{"result" => %{"stopReason" => "end_turn"}} = receive_raw(transport)

    assert {:ok, nil} = call_mcp(agent, transport, "ping", nil, request_id: "after")
  end

  test "rejects a frame over max_frame_bytes without sending it" do
    {agent, transport, peer} = boot(max_frame_bytes: 4_096)
    open_session!(transport, 2, [acp("Tools", "tools")])

    assert {:error, :frame_too_large} =
             Agent.mcp_request(agent, "sess-1", "tools", "tools/list",
               params: %{"blob" => String.duplicate("x", 8_000)}
             )

    refute_outbound(peer)
  end

  test "does not bind a stdio server and still binds the acp server beside it" do
    {agent, transport, _peer} = boot()

    stdio = %{
      "name" => "local",
      "command" => "/bin/true",
      "args" => [],
      "env" => []
    }

    open_session!(transport, 2, [stdio, acp("Tools", "tools")])

    assert {:error, :unknown_mcp_server} =
             Agent.mcp_request(agent, "sess-1", "local", "tools/list")

    assert {:ok, []} = call_mcp(agent, transport, "tools/list", [])
  end

  test "rejects an infinite timeout and a non-object params, and sends an empty request id" do
    {agent, transport, peer} = boot()
    open_session!(transport, 2, [acp("Tools", "tools")])

    assert_raise ArgumentError, fn ->
      Agent.mcp_request(agent, "sess-1", "tools", "tools/list", timeout: :infinity)
    end

    assert_raise ArgumentError, fn ->
      Agent.mcp_request(agent, "sess-1", "tools", "tools/list", request_id: <<0xFF>>)
    end

    assert {:error, :invalid_params} =
             Agent.mcp_request(agent, "sess-1", "tools", "tools/list", params: %{name: "echo"})

    refute_outbound(peer)

    task = async_mcp(agent, "tools/list", request_id: "")
    request = receive_raw(transport)
    assert request["params"]["requestId"] == ""
    assert request["params"]["serverId"] == "tools"
    reply_result(transport, request, %{"ok" => true})
    assert {:ok, %{"ok" => true}} = Task.await(task)
  end

  test "binds an empty server id and calls it with an empty method" do
    {agent, transport, _peer} = boot()
    open_session!(transport, 2, [acp("", "")])

    task = async_mcp(agent, "", server_id: "", request_id: "")
    request = receive_raw(transport)
    assert request["params"]["serverId"] == ""
    assert request["params"]["requestId"] == ""
    assert request["params"]["method"] == ""
    reply_result(transport, request, [])
    assert {:ok, []} = Task.await(task)
  end

  test "mcp_request follows the capabilities handle_initialize sent" do
    quiet = Types.agent_capabilities(load_session: true, session_close: true)

    {agent, transport, _peer} =
      boot(agent_capabilities: quiet, handler_opts: [advertise_acp: true])

    assert Arbor.ACP.Capabilities.supported?(
             :sys.get_state(agent).agent_capabilities,
             :mcp_acp
           )

    open_session!(transport, 2, [acp("Tools", "tools")])
    task = async_mcp(agent, "tools/list")
    monitor = Process.monitor(task.pid)

    receive do
      {:DOWN, ^monitor, :process, _pid, reason} ->
        flunk("mcp_request finished before a frame: #{inspect(reason)}")
    after
      100 -> :ok
    end

    request = receive_raw(transport)
    assert request["method"] == "mcp/message"
    reply_result(transport, request, %{"tools" => []})
    assert {:ok, %{"tools" => []}} = Task.await(task)
    Process.demonitor(monitor, [:flush])

    {agent, transport, peer} =
      boot(agent_capabilities: acp_capabilities(), handler_opts: [advertise_acp: false])

    refute Arbor.ACP.Capabilities.supported?(:sys.get_state(agent).agent_capabilities, :mcp_acp)
    open_session!(transport, 2, [acp("Tools", "tools")])

    assert {:error, {:unsupported_capability, :acp_mcp}} =
             Agent.mcp_request(agent, "sess-1", "tools", "tools/list", timeout: 200)

    refute_outbound(peer)
  end

  defp acp(name, server_id), do: Types.acp_mcp_server(name, server_id)

  defp acp_capabilities do
    Types.agent_capabilities(
      acp_mcp: true,
      load_session: true,
      session_resume: true,
      session_close: true,
      session_delete: true,
      session_fork: true
    )
  end

  defp boot(opts \\ []) do
    {:ok, peer} = Memory.new_pair()

    agent_opts =
      [
        handler: McpAgent,
        handler_opts: Keyword.merge([test_pid: self()], Keyword.get(opts, :handler_opts, [])),
        transport: {:memory, peer},
        agent_capabilities: Keyword.get(opts, :agent_capabilities, acp_capabilities())
      ]
      |> maybe_opt(opts, :pending_request_timeout)
      |> maybe_opt(opts, :max_pending_requests)
      |> maybe_opt(opts, :max_frame_bytes)
      |> maybe_opt(opts, :max_extension_queue)

    {:ok, agent} = Agent.start_link(agent_opts)
    {:ok, transport} = Memory.connect(peer: peer, role: :client)
    initialize!(transport)
    {agent, transport, peer}
  end

  defp maybe_opt(agent_opts, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Keyword.put(agent_opts, key, value)
      :error -> agent_opts
    end
  end

  defp initialize!(transport) do
    send_raw(transport, 1, "initialize", %{
      "protocolVersion" => 1,
      "clientCapabilities" => %{}
    })

    assert %{"result" => %{"protocolVersion" => 1}} = receive_raw(transport)
  end

  defp open_session(transport, id, servers, meta \\ nil) do
    params = %{"cwd" => "/tmp", "mcpServers" => servers}
    params = if meta, do: Map.put(params, "_meta", meta), else: params
    send_raw(transport, id, "session/new", params)
    receive_raw(transport)
  end

  defp open_session!(transport, id, servers, meta \\ nil) do
    response = open_session(transport, id, servers, meta)
    assert %{"result" => %{"sessionId" => _}} = response
    response
  end

  defp lifecycle(transport, id, method, params) do
    send_raw(transport, id, method, Map.put_new(params, "cwd", "/tmp"))
    receive_raw(transport)
  end

  defp async_mcp(agent, method, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "sess-1")
    server_id = Keyword.get(opts, :server_id, "tools")
    opts = Keyword.drop(opts, [:session_id, :server_id])
    Task.async(fn -> Agent.mcp_request(agent, session_id, server_id, method, opts) end)
  end

  defp call_mcp(agent, transport, method, outcome, opts \\ []) do
    task = async_mcp(agent, method, opts)
    request = receive_raw(transport)

    case outcome do
      :mcp_error ->
        send_raw_message(
          transport,
          Protocol.encode_mcp_error(request["id"], %{"code" => -32_001, "message" => "missing"})
        )

      other ->
        reply_result(transport, request, other)
    end

    Task.await(task)
  end

  defp reply_result(transport, request, result) do
    send_raw_message(transport, Protocol.encode_mcp_result(request["id"], result))
  end

  defp send_raw(transport, id, method, params) do
    message =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

    assert {:ok, _transport} = Memory.send_message(message, transport)
  end

  defp send_raw_message(transport, message) do
    encoded = if is_binary(message), do: message, else: Jason.encode!(message)
    assert {:ok, _transport} = Memory.send_message(encoded, transport)
  end

  defp send_json(transport, message), do: send_raw_message(transport, message)

  defp receive_raw(transport) do
    assert {:ok, message, _transport} = Memory.receive_message(transport)
    Jason.decode!(message)
  end

  defp refute_outbound(peer) do
    %{queues: queues} = :sys.get_state(peer)
    assert :queue.is_empty(queues.client)
  end
end
