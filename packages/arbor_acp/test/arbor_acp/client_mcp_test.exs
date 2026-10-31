defmodule Arbor.ACP.ClientMcpTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arbor.ACP.Agent.Transport.Memory
  alias Arbor.ACP.Client
  alias Arbor.ACP.Protocol
  alias Arbor.ACP.Types
  alias Arbor.RPC.LogSummary

  defmodule McpHandler do
    @behaviour Arbor.ACP.Client.Handler

    @impl true
    def init(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         seen: 0,
         updates: 0,
         block_updates: Keyword.get(opts, :block_updates, false)
       }}
    end

    @impl true
    def handle_session_update(_session_id, _update, %{block_updates: true} = state) do
      send(state.test_pid, {:update_blocking, self()})

      receive do
        :release_update ->
          state = %{state | updates: state.updates + 1, block_updates: false}
          send(state.test_pid, {:session_updated, state.updates})
          {:ok, state}
      end
    end

    def handle_session_update(_session_id, _update, state) do
      state = %{state | updates: state.updates + 1}
      send(state.test_pid, {:session_updated, state.updates})
      {:ok, state}
    end

    @impl true
    def handle_permission_request(_session_id, _tool_call, _options, state) do
      send(state.test_pid, {:permission, self()})
      {:ok, %{"outcome" => "cancelled"}, state}
    end

    @impl true
    def handle_file_read(_session_id, _path, _opts, state) do
      send(state.test_pid, {:file_read, self()})
      {:ok, "contents", state}
    end

    @impl true
    def handle_terminal_request(_method, _params, _id, state) do
      send(state.test_pid, {:terminal, self()})
      {:ok, %{"terminalId" => "term-1"}, state}
    end

    @impl true
    def handle_mcp_request(session_id, request, context, state) do
      send(state.test_pid, {:handler_mcp, session_id, request, context})

      case request["method"] do
        "tools/list" ->
          {:ok, %{"tools" => [], "n" => state.seen}, %{state | seen: state.seen + 1}}

        "block" ->
          send(state.test_pid, {:blocking, self()})

          receive do
            :release -> {:ok, %{"released" => true}, state}
          end

        "count" ->
          send(state.test_pid, {:counting, state.seen, state.updates, self()})

          receive do
            :release ->
              {:ok, %{"n" => state.seen, "updates" => state.updates}, state}
          end

        "mutate" ->
          {:ok, %{"n" => state.seen}, %{state | seen: state.seen + 1}}

        "outer" ->
          send(state.test_pid, {:outer, self()})

          receive do
            :release -> {:ok, %{"nested" => true}, state}
          end

        "inner" ->
          send(state.test_pid, {:inner, self()})
          {:ok, %{"inner" => true}, state}

        "fail" ->
          {:error, :nope, state}

        _other ->
          {:mcp_error, %{"code" => -32_001, "message" => "missing"}, state}
      end
    end
  end

  defmodule BlockingProvider do
    @behaviour Arbor.ACP.Client.McpProvider

    @impl true
    def handle_mcp_request(_context, %{"method" => "block"}) do
      receive do
        :release -> {:ok, %{"released" => true}}
      end
    end

    def handle_mcp_request(_context, _request), do: {:ok, %{"tools" => []}}
  end

  defmodule ModuleProvider do
    @behaviour Arbor.ACP.Client.McpProvider

    @impl true
    def handle_mcp_request(_context, %{"method" => "tools/list"}),
      do: {:ok, %{"tools" => ["module"]}}

    def handle_mcp_request(_context, %{"method" => "null"}), do: {:ok, nil}

    def handle_mcp_request(_context, _request),
      do: {:mcp_error, %{"code" => -32_002, "message" => "module"}}
  end

  test "a pid provider returns a result, null, an inner error, and an outer failure" do
    parent = self()
    provider = provider_loop(parent)
    ctx = boot(mcp_providers: %{"tools" => provider})
    open_session(ctx, [acp("Tools", "tools")])

    assert_mcp_result(ctx, provider, "tools/list", %{"tools" => []})
    assert_mcp_result(ctx, provider, "null", nil)

    id = agent_mcp(ctx, "tools", "err", "tools/call")
    assert_receive {:provider, ref, _context, _params}
    send(provider, {:reply, ref, {:mcp_error, %{"code" => -32_001, "message" => "missing"}}})
    response = await_frame()
    assert response["id"] == id
    assert response["result"]["error"] == %{"code" => -32_001, "message" => "missing"}
    refute Map.has_key?(response, "error")

    id = agent_mcp(ctx, "tools", "bad", "tools/call")
    assert_receive {:provider, ref, _context, _params}
    send(provider, {:reply, ref, {:error, :nope}})
    assert_provider_unavailable(await_frame(), id)

    id = agent_mcp(ctx, "tools", "atom", "tools/call")
    assert_receive {:provider, ref, _context, _params}
    send(provider, {:reply, ref, {:ok, :not_json}})
    assert_provider_unavailable(await_frame(), id)
  end

  test "notifies only while the inner request is in flight" do
    provider = provider_loop(self())
    ctx = boot(mcp_providers: %{"tools" => provider})
    open_session(ctx, [acp("Tools", "tools")])

    id = agent_mcp(ctx, "tools", "r1", "tools/list", %{})
    assert_receive {:provider, ref, context, params}
    assert context.client == ctx.client
    assert context.session_id == "sess-1"
    assert context.server_id == "tools"
    assert is_reference(context.token)
    assert params["requestId"] == "r1"

    assert {:error, :unknown_mcp_request} =
             Client.mcp_notify(ctx.client, "tools", "r1", "notifications/progress")

    assert {:error, :unknown_mcp_request} =
             Client.mcp_notify(ctx.client, "tools", "r1", "notifications/progress",
               token: context.token,
               session_id: "other"
             )

    assert :ok =
             Client.mcp_notify(ctx.client, "tools", "r1", "notifications/progress",
               token: context.token,
               session_id: "sess-1",
               params: %{"progress" => 1},
               meta: %{"source" => "provider"}
             )

    note = await_frame()
    refute Map.has_key?(note, "id")
    assert note["method"] == "mcp/message"
    assert note["params"]["serverId"] == "tools"
    assert note["params"]["requestId"] == "r1"
    assert note["params"]["params"] == %{"progress" => 1}
    assert note["params"]["_meta"] == %{"source" => "provider"}

    send(provider, {:reply, ref, {:ok, %{"tools" => []}}})
    assert %{"id" => ^id} = await_frame()

    assert {:error, :unknown_mcp_request} =
             Client.mcp_notify(ctx.client, "tools", "r1", "notifications/progress")

    refute_outbound(ctx)
  end

  test "a module provider and the handler provider serve the request" do
    ctx =
      boot(
        handler: McpHandler,
        handler_opts: [test_pid: self()],
        mcp_providers: %{"mod" => ModuleProvider, "app" => :handler}
      )

    open_session(ctx, [acp("Module", "mod"), acp("App", "app")])

    id = agent_mcp(ctx, "mod", "m1", "tools/list")
    assert %{"id" => ^id, "result" => %{"result" => %{"tools" => ["module"]}}} = await_frame()

    id = agent_mcp(ctx, "mod", "m2", "null")
    response = await_frame()
    assert response["id"] == id
    assert response["result"]["result"] == nil

    id = agent_mcp(ctx, "mod", "m3", "missing")

    assert %{"id" => ^id, "result" => %{"error" => %{"code" => -32_002, "message" => "module"}}} =
             await_frame()

    id = agent_mcp(ctx, "app", "a1", "tools/list")
    assert_receive {:handler_mcp, "sess-1", %{"method" => "tools/list"}, context}
    assert context.request_id == "a1"
    assert %{"id" => ^id, "result" => %{"result" => %{"tools" => [], "n" => 0}}} = await_frame()

    id = agent_mcp(ctx, "app", "a2", "tools/list")
    assert_receive {:handler_mcp, "sess-1", _request, _context}
    assert %{"id" => ^id, "result" => %{"result" => %{"n" => 0}}} = await_frame()

    id = agent_mcp(ctx, "app", "a3", "fail")
    assert_receive {:handler_mcp, "sess-1", _request, _context}
    assert_provider_unavailable(await_frame(), id)
  end

  test "a handler that does not export the callback answers that the provider is unavailable" do
    ctx = boot(mcp_providers: %{"tools" => :handler})
    open_session(ctx, [acp("Tools", "tools")])
    id = agent_mcp(ctx, "tools", "r1", "tools/list")
    assert_provider_unavailable(await_frame(), id)
  end

  test "omits an ACP server when the capability is not exactly true and still opens the session" do
    secret = "secret-server-#{System.unique_integer([:positive])}"
    ctx = boot(advertise: false)
    servers = [stdio(), http(), sse(), acp("Hidden", secret)]

    log =
      with_info_log(fn ->
        task = Task.async(fn -> Client.new_session(ctx.client, "/tmp", mcp_servers: servers) end)
        request = await_frame()
        assert request["params"]["mcpServers"] == [stdio(), http(), sse()]
        send_result(ctx.outbound, request["id"], %{"sessionId" => "sess-1"})
        assert {:ok, %{"sessionId" => "sess-1"}} = Task.await(task, 5_000)
      end)

    refute log =~ secret
    assert log =~ "mcp_acp_not_advertised"
    assert log =~ LogSummary.fingerprint(secret)

    id = agent_mcp(ctx, secret, "r1", "tools/list")
    assert_unknown_server(await_frame(), id)
  end

  test "a capability object loses to the boolean check before a missing provider is considered" do
    ctx = boot(advertise: :object)

    log =
      with_info_log(fn ->
        request = open_session(ctx, [acp("Tools", "tools")])
        assert request["params"]["mcpServers"] == []
      end)

    assert log =~ "mcp_acp_not_advertised"
    refute log =~ "mcp_provider_not_configured"
  end

  test "omits an advertised ACP server that has no provider and keeps stdio" do
    ctx = boot()

    log =
      with_info_log(fn ->
        request = open_session(ctx, [stdio(), acp("Tools", "tools")])
        assert request["params"]["mcpServers"] == [stdio()]
      end)

    assert log =~ "mcp_provider_not_configured"
    refute log =~ "tools"
  end

  test "rejects a malformed ACP server before sending the session" do
    ctx = boot()

    assert {:error, {:invalid_params, :mcp_server}} =
             Client.new_session(ctx.client, "/tmp",
               mcp_servers: [%{"type" => "acp", "name" => "Tools"}]
             )

    refute_outbound(ctx)
  end

  test "rejects a duplicate ACP server id and an id already in use before sending" do
    provider = provider_loop(self())
    ctx = boot(mcp_providers: %{"tools" => provider, "other" => provider})
    open_session(ctx, [acp("Tools", "tools")])

    assert {:error, {:invalid_params, :duplicate_mcp_server_id}} =
             Client.new_session(ctx.client, "/tmp",
               mcp_servers: [acp("Tools", "tools"), acp("Alias", "tools")]
             )

    refute_outbound(ctx)

    assert {:error, {:invalid_params, :mcp_server_id_in_use}} =
             Client.new_session(ctx.client, "/tmp", mcp_servers: [acp("Again", "tools")])

    refute_outbound(ctx)
  end

  test "answers unknown, pending, and gone servers with an outer error" do
    provider = provider_loop(self())
    ctx = boot(mcp_providers: %{"tools" => provider})

    task =
      Task.async(fn ->
        Client.new_session(ctx.client, "/tmp", mcp_servers: [acp("Tools", "tools")])
      end)

    request = await_frame()
    id = agent_mcp(ctx, "tools", "early", "tools/list")
    assert_unknown_server(await_frame(), id)
    send_result(ctx.outbound, request["id"], %{"sessionId" => "sess-1"})
    assert {:ok, _} = Task.await(task, 5_000)

    id = agent_mcp(ctx, "missing", "r1", "tools/list")
    assert_unknown_server(await_frame(), id)

    :sys.replace_state(ctx.client, fn state ->
      %{state | sessions: Map.delete(state.sessions, "sess-1")}
    end)

    id = agent_mcp(ctx, "tools", "gone", "tools/list")
    response = await_frame()
    assert response["id"] == id
    assert response["error"]["code"] == -32_602
    assert response["error"]["message"] == "Unknown session"
  end

  test "rejects a duplicate in-flight inner request id" do
    provider = provider_loop(self())
    ctx = boot(mcp_providers: %{"tools" => provider})
    open_session(ctx, [acp("Tools", "tools")])
    _id = agent_mcp(ctx, "tools", "same", "tools/list")
    assert_receive {:provider, _ref, _context, _params}
    duplicate = agent_mcp(ctx, "tools", "same", "tools/list")
    response = await_frame()
    assert response["id"] == duplicate
    assert response["error"]["code"] == -32_600
    assert response["error"]["message"] == "Request id is already in use"
  end

  test "drops a dead provider, keeps the binding, and refuses to replace it" do
    provider = provider_loop(self())
    replacement = provider_loop(self())
    ctx = boot(mcp_providers: %{"tools" => provider})
    open_session(ctx, [acp("Tools", "tools")])
    id = agent_mcp(ctx, "tools", "r1", "tools/list")
    assert_receive {:provider, _ref, _context, _params}
    Process.exit(provider, :kill)
    assert_provider_unavailable(await_frame(), id)
    refute Map.has_key?(:sys.get_state(ctx.client).mcp_providers, "tools")

    assert {:error, :mcp_server_id_in_use} =
             Client.register_mcp_provider(ctx.client, "tools", replacement)

    assert {:error, :mcp_server_id_in_use} = Client.unregister_mcp_provider(ctx.client, "tools")
    id = agent_mcp(ctx, "tools", "r2", "tools/list")
    assert_provider_unavailable(await_frame(), id)
  end

  test "close and local end_session release ids and cancel provider work" do
    provider = provider_loop(self())
    ctx = boot(mcp_providers: %{"tools" => provider})
    open_session(ctx, [acp("Tools", "tools")])
    id = agent_mcp(ctx, "tools", "r1", "tools/list")
    assert_receive {:provider, _ref, _context, _params}

    task = Task.async(fn -> Client.close_session(ctx.client, "sess-1") end)
    close = await_frame()
    assert close["method"] == "session/close"
    send_result(ctx.outbound, close["id"], %{})
    assert_cancelled(await_frame(), id)
    assert {:ok, %{}} = Task.await(task, 5_000)
    assert :ok = Client.register_mcp_provider(ctx.client, "tools", provider)

    local = provider_loop(self())
    ctx = boot(close: false, mcp_providers: %{"tools" => local})
    open_session(ctx, [acp("Tools", "tools")], "sess-local")
    id = agent_mcp(ctx, "tools", "r2", "tools/list")
    assert_receive {:provider, _ref, _context, _params}
    assert :ok = Client.end_session(ctx.client, "sess-local")
    assert_cancelled(await_frame(), id)
    id = agent_mcp(ctx, "tools", "r3", "tools/list")
    assert_unknown_server(await_frame(), id)
  end

  test "resume without mcp servers clears the ACP set, and a failed open releases the reservation" do
    provider = provider_loop(self())
    ctx = boot(mcp_providers: %{"tools" => provider, "next" => provider})
    open_session(ctx, [acp("Tools", "tools")])

    task = Task.async(fn -> Client.resume_session(ctx.client, "sess-1", "/tmp") end)
    request = await_frame()
    assert request["method"] == "session/resume"
    assert request["params"]["mcpServers"] == []
    send_result(ctx.outbound, request["id"], %{})
    assert {:ok, _} = Task.await(task, 5_000)
    id = agent_mcp(ctx, "tools", "gone", "tools/list")
    assert_unknown_server(await_frame(), id)

    task =
      Task.async(fn ->
        Client.new_session(ctx.client, "/tmp", mcp_servers: [acp("Next", "next")])
      end)

    request = await_frame()
    send_error(ctx.outbound, request["id"], -32_603, "nope")
    assert {:error, %{"code" => -32_603, "message" => "nope"}} = Task.await(task, 5_000)
    open_session(ctx, [acp("Next", "next")], "sess-2")
  end

  test "load replaces the set and a failed load keeps the previous binding" do
    docs = provider_loop(self())
    tools = provider_loop(self())
    ctx = boot(mcp_providers: %{"tools" => tools, "docs" => docs})
    open_session(ctx, [acp("Tools", "tools"), acp("Docs", "docs")])
    id = agent_mcp(ctx, "docs", "d1", "resources/read")
    assert_receive {:provider, _ref, _context, %{"serverId" => "docs"}}

    task =
      Task.async(fn ->
        Client.load_session(ctx.client, "sess-1", "/tmp", mcp_servers: [acp("Tools", "tools")])
      end)

    request = await_frame()
    assert request["method"] == "session/load"
    send_error(ctx.outbound, request["id"], -32_603, "nope")
    assert {:error, %{"message" => "nope"}} = Task.await(task, 5_000)
    refute_outbound(ctx)

    task =
      Task.async(fn ->
        Client.load_session(ctx.client, "sess-1", "/tmp", mcp_servers: [acp("Tools", "tools")])
      end)

    request = await_frame()
    send_result(ctx.outbound, request["id"], %{"sessionId" => "different"})
    assert_cancelled(await_frame(), id)
    assert {:ok, _} = Task.await(task, 5_000)

    id = agent_mcp(ctx, "docs", "d2", "resources/read")
    assert_unknown_server(await_frame(), id)
    id = agent_mcp(ctx, "tools", "t1", "tools/list")
    assert_receive {:provider, ref, _context, %{"serverId" => "tools"}}
    send(tools, {:reply, ref, {:ok, %{"tools" => []}}})
    assert %{"id" => ^id, "result" => %{"result" => %{"tools" => []}}} = await_frame()
  end

  test "fork cannot reuse a parent id and binds the ids it supplies" do
    provider = provider_loop(self())
    ctx = boot(mcp_providers: %{"tools" => provider, "forked" => provider})
    open_session(ctx, [acp("Tools", "tools")])

    assert {:error, {:invalid_params, :mcp_server_id_in_use}} =
             Client.fork_session(ctx.client, "sess-1", "/tmp",
               mcp_servers: [acp("Tools", "tools")]
             )

    refute_outbound(ctx)

    task =
      Task.async(fn ->
        Client.fork_session(ctx.client, "sess-1", "/tmp", mcp_servers: [acp("Fork", "forked")])
      end)

    request = await_frame()
    assert request["params"]["mcpServers"] == [acp("Fork", "forked")]
    send_result(ctx.outbound, request["id"], %{"sessionId" => "sess-fork"})
    assert {:ok, %{"sessionId" => "sess-fork"}} = Task.await(task, 5_000)

    id = agent_mcp(ctx, "tools", "parent", "tools/list")
    assert_receive {:provider, ref, %{session_id: "sess-1"}, _params}
    send(provider, {:reply, ref, {:ok, %{"ok" => true}}})
    assert %{"id" => ^id} = await_frame()

    id = agent_mcp(ctx, "forked", "child", "tools/list")
    assert_receive {:provider, ref, %{session_id: "sess-fork"}, _params}
    send(provider, {:reply, ref, {:ok, %{"ok" => true}}})
    assert %{"id" => ^id} = await_frame()
  end

  test "the pending-request cap and a stalled provider use the existing limits" do
    provider = provider_loop(self())
    ctx = boot(mcp_providers: %{"tools" => provider}, max_pending_requests: 1)
    open_session(ctx, [acp("Tools", "tools")])
    _id = agent_mcp(ctx, "tools", "r1", "tools/list")
    assert_receive {:provider, _ref, _context, _params}
    blocked = agent_mcp(ctx, "tools", "r2", "tools/list")
    response = await_frame()
    assert response["id"] == blocked
    assert response["error"]["code"] == -32_000
    assert response["error"]["message"] == "Too many pending requests"

    ctx =
      boot(mcp_providers: %{"tools" => provider_loop(self())}, handler_request_timeout: 80)

    open_session(ctx, [acp("Tools", "tools")], "sess-timeout")
    id = agent_mcp(ctx, "tools", "slow", "tools/list")
    assert_receive {:provider, _ref, _context, _params}
    assert_provider_unavailable(await_frame(), id)
  end

  test "a notification larger than the frame cap is not sent" do
    provider = provider_loop(self())
    ctx = boot(mcp_providers: %{"tools" => provider}, max_frame_bytes: 4_096)
    open_session(ctx, [acp("Tools", "tools")])
    _id = agent_mcp(ctx, "tools", "r1", "tools/list")
    assert_receive {:provider, _ref, context, _params}

    assert {:error, :frame_too_large} =
             Client.mcp_notify(ctx.client, "tools", "r1", "notifications/progress",
               token: context.token,
               params: %{"blob" => String.duplicate("x", 8_000)}
             )

    refute_outbound(ctx)

    assert :ok =
             Client.mcp_notify(ctx.client, "tools", "r1", "notifications/progress",
               token: context.token,
               params: %{"progress" => 1}
             )

    assert %{"method" => "mcp/message"} = await_frame()
  end

  test "cancel_request finishes the provider call and prompt cancel does not" do
    provider = provider_loop(self())
    ctx = boot(mcp_providers: %{"tools" => provider})
    open_session(ctx, [acp("Tools", "tools")])
    id = agent_mcp(ctx, "tools", "r1", "tools/list")
    assert_receive {:provider, ref, context, _params}
    :ok = Client.cancel(ctx.client, "sess-1")
    assert %{"method" => "session/cancel"} = await_frame()

    assert :ok =
             Client.mcp_notify(ctx.client, "tools", "r1", "notifications/progress",
               token: context.token
             )

    assert %{"method" => "mcp/message"} = await_frame()

    send_json(ctx.outbound, Protocol.encode_cancel_request(id))
    assert_cancelled(await_frame(), id)
    send(provider, {:reply, ref, {:ok, %{"late" => true}}})

    assert {:error, :unknown_mcp_request} =
             Client.mcp_notify(ctx.client, "tools", "r1", "notifications/progress")

    refute_outbound(ctx)
  end

  test "notify rejects a caller inside the client and a non-JSON params object" do
    ctx = boot()

    assert_raise ArgumentError, ~r/client process/, fn ->
      Client.mcp_notify(self(), "tools", "r1", "notifications/progress")
    end

    assert {:error, :invalid_params} =
             Client.mcp_notify(ctx.client, "tools", "r1", "notifications/progress",
               params: %{a: 1}
             )

    assert {:error, :invalid_params} =
             Client.mcp_notify(ctx.client, "tools", "r1", "notifications/progress", token: "nope")
  end

  test "start_link rejects a provider map that cannot be installed" do
    assert {:error, {:invalid_params, :mcp_provider}} =
             start_quietly(mcp_providers: %{"ok" => :missing}, _skip_connect: true)

    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    refute Process.alive?(pid)

    assert {:error, {:invalid_params, :mcp_provider}} =
             start_quietly(mcp_providers: %{"gone" => pid}, _skip_connect: true)

    ctx = boot()
    assert :ok = Client.register_mcp_provider(ctx.client, "", :handler)

    assert {:error, :invalid_params} =
             Client.register_mcp_provider(ctx.client, <<0xFF>>, :handler)
  end

  test "a closed session's notify token cannot reach the request that reused its ids" do
    provider = provider_loop(self())
    ctx = boot(mcp_providers: %{"tools" => provider})
    open_session(ctx, [acp("Tools", "tools")])
    id = agent_mcp(ctx, "tools", "r1", "tools/list")
    assert_receive {:provider, first_ref, first, _params}

    task = Task.async(fn -> Client.close_session(ctx.client, "sess-1") end)
    close = await_frame()
    send_result(ctx.outbound, close["id"], %{})
    assert_cancelled(await_frame(), id)
    assert {:ok, %{}} = Task.await(task, 5_000)
    send(provider, {:reply, first_ref, {:ok, %{"late" => true}}})

    open_session(ctx, [acp("Tools", "tools")], "sess-2")
    _id = agent_mcp(ctx, "tools", "r1", "tools/list")
    assert_receive {:provider, _ref, second, _params}

    assert {:error, :unknown_mcp_request} =
             Client.mcp_notify(ctx.client, "tools", "r1", "notifications/progress",
               token: first.token
             )

    refute_outbound(ctx)

    assert :ok =
             Client.mcp_notify(ctx.client, "tools", "r1", "notifications/progress",
               token: second.token,
               params: %{"progress" => 1}
             )

    assert %{"method" => "mcp/message"} = await_frame()
  end

  test "a load that keeps a server id holds it against a concurrent release" do
    provider = provider_loop(self())
    ctx = boot(mcp_providers: %{"tools" => provider})
    open_session(ctx, [acp("Tools", "tools")])

    task =
      Task.async(fn ->
        Client.load_session(ctx.client, "sess-1", "/tmp", mcp_servers: [acp("Tools", "tools")])
      end)

    request = await_frame()
    assert request["method"] == "session/load"

    assert {:error, {:invalid_params, :mcp_server_id_in_use}} =
             Client.load_session(ctx.client, "sess-1", "/tmp", mcp_servers: [], timeout: 200)

    refute_outbound(ctx)
    send_result(ctx.outbound, request["id"], %{})
    assert {:ok, _} = Task.await(task, 5_000)

    id = agent_mcp(ctx, "tools", "t1", "tools/list")
    assert_receive {:provider, ref, _context, _params}
    send(provider, {:reply, ref, {:ok, %{"ok" => true}}})
    assert %{"id" => ^id, "result" => %{"result" => %{"ok" => true}}} = await_frame()
  end

  test "an oversized provider result becomes an outer error and finishes the request" do
    provider = provider_loop(self())
    ctx = boot(mcp_providers: %{"tools" => provider}, max_frame_bytes: 512)
    open_session(ctx, [acp("Tools", "tools")])
    id = agent_mcp(ctx, "tools", "huge", "tools/list")
    assert_receive {:provider, ref, context, _params}

    send(provider, {:reply, ref, {:ok, %{"blob" => String.duplicate("x", 2_000)}}})
    assert_provider_unavailable(await_frame(), id)

    assert {:error, :unknown_mcp_request} =
             Client.mcp_notify(ctx.client, "tools", "huge", "notifications/progress",
               token: context.token
             )

    id = agent_mcp(ctx, "tools", "small", "tools/list")
    assert_receive {:provider, ref, _context, _params}
    send(provider, {:reply, ref, {:ok, %{"ok" => true}}})
    assert %{"id" => ^id, "result" => %{"result" => %{"ok" => true}}} = await_frame()
  end

  test "reports omitted ACP servers on the session result and emits telemetry" do
    secret = "secret-server-#{System.unique_integer([:positive])}"
    ctx = boot(advertise: false)
    handler_id = "mcp-omitted-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:arbor_acp, :mcp, :server, :omitted],
      fn event, measurements, metadata, _config ->
        send(parent, {:omitted, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      with_info_log(fn ->
        task =
          Task.async(fn ->
            Client.new_session(ctx.client, "/tmp", mcp_servers: [acp("Hidden", secret), stdio()])
          end)

        request = await_frame()
        assert request["params"]["mcpServers"] == [stdio()]
        send_result(ctx.outbound, request["id"], %{"sessionId" => "sess-1"})
        assert {:ok, result} = Task.await(task, 5_000)
        send(parent, {:session, result})
      end)

    assert_receive {:session, result}
    assert result["sessionId"] == "sess-1"

    assert result["omittedMcpServers"] == [
             %{"serverId" => secret, "reason" => "mcp_acp_not_advertised"}
           ]

    assert_receive {:omitted, [:arbor_acp, :mcp, :server, :omitted], %{count: 1}, metadata}
    assert metadata.reason == :mcp_acp_not_advertised
    assert metadata.server_id_hash == LogSummary.fingerprint(secret)
    refute Map.has_key?(metadata, :id)
    refute log =~ secret

    :telemetry.detach(handler_id)

    task = Task.async(fn -> Client.new_session(ctx.client, "/tmp", mcp_servers: [stdio()]) end)
    request = await_frame()
    send_result(ctx.outbound, request["id"], %{"sessionId" => "sess-2"})
    assert {:ok, plain} = Task.await(task, 5_000)
    refute Map.has_key?(plain, "omittedMcpServers")
  end

  test "accepts an empty ACP server id and request id" do
    provider = provider_loop(self())
    ctx = boot(mcp_providers: %{"" => provider})
    open_session(ctx, [acp("", "")])
    id = agent_mcp(ctx, "", "", "tools/list")
    assert_receive {:provider, ref, context, params}
    assert context.server_id == ""
    assert context.request_id == ""
    assert params["method"] == "tools/list"
    send(provider, {:reply, ref, {:ok, %{"ok" => true}}})
    assert %{"id" => ^id, "result" => %{"result" => %{"ok" => true}}} = await_frame()
  end

  test "a timed-out module provider is stopped and the next request still runs" do
    ctx =
      boot(
        mcp_providers: %{"tools" => BlockingProvider},
        handler_request_timeout: 1_000
      )

    open_session(ctx, [acp("Tools", "tools")], "sess-block")
    id = agent_mcp(ctx, "tools", "slow", "block")
    worker = await_mcp_worker(ctx.client)
    assert is_pid(worker)
    monitor = Process.monitor(worker)
    assert_provider_unavailable(await_frame(), id)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

    id = agent_mcp(ctx, "tools", "next", "tools/list")
    assert %{"id" => ^id, "result" => %{"result" => %{"tools" => []}}} = await_frame()
  end

  test "a timed-out handler provider is stopped and the next request still runs" do
    ctx =
      boot(
        handler: McpHandler,
        handler_opts: [test_pid: self()],
        mcp_providers: %{"app" => :handler},
        handler_request_timeout: 80
      )

    open_session(ctx, [acp("App", "app")], "sess-handler")
    id = agent_mcp(ctx, "app", "slow", "block")
    assert_receive {:blocking, worker}
    monitor = Process.monitor(worker)
    assert_provider_unavailable(await_frame(), id)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

    id = agent_mcp(ctx, "app", "next", "tools/list")
    assert_receive {:handler_mcp, "sess-handler", %{"method" => "tools/list"}, _context}
    assert %{"id" => ^id, "result" => %{"result" => %{"n" => 0}}} = await_frame()
  end

  test "handler callbacks run concurrently and a changed state is discarded" do
    ctx =
      boot(
        handler: McpHandler,
        handler_opts: [test_pid: self()],
        mcp_providers: %{"app" => :handler}
      )

    open_session(ctx, [acp("App", "app")], "sess-count")

    first_id = agent_mcp(ctx, "app", "c1", "count")
    assert_receive {:counting, 0, 0, first}
    second_id = agent_mcp(ctx, "app", "c2", "count")
    assert_receive {:counting, 0, 0, second}
    assert map_size(handler_runner(ctx).mcp_workers) == 2
    send(first, :release)
    send(second, :release)

    # Both workers are already released, so either response may arrive first.
    assert_receive {:from_client, %{"id" => ^first_id} = first_response}, 5_000
    assert_receive {:from_client, %{"id" => ^second_id} = second_response}, 5_000

    assert first_response["result"] == %{"result" => %{"n" => 0, "updates" => 0}}
    assert second_response["result"] == %{"result" => %{"n" => 0, "updates" => 0}}

    handler_id = "mcp-state-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:arbor_acp, :mcp, :handler, :state_discarded],
      fn event, measurements, metadata, _config ->
        send(parent, {:discarded, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        mutated = agent_mcp(ctx, "app", "c3", "mutate")
        assert_receive {:handler_mcp, "sess-count", %{"method" => "mutate"}, context}
        assert context.session_id == "sess-count"

        assert %{"id" => ^mutated, "result" => %{"result" => %{"n" => 0}}} = await_frame()
        send(parent, :mutated)
      end)

    assert_receive :mutated

    assert_receive {:discarded, [:arbor_acp, :mcp, :handler, :state_discarded], %{count: 1},
                    metadata}

    assert metadata.session_id_hash == LogSummary.fingerprint("sess-count")
    refute Map.has_key?(metadata, :state)
    assert log =~ "changed state"
    refute log =~ "sess-count"

    third_id = agent_mcp(ctx, "app", "c4", "tools/list")
    assert_receive {:handler_mcp, "sess-count", %{"method" => "tools/list"}, _context}
    assert %{"id" => ^third_id, "result" => %{"result" => %{"n" => 0}}} = await_frame()
  end

  test "a nested handler request runs while the outer callback is waiting" do
    ctx =
      boot(
        handler: McpHandler,
        handler_opts: [test_pid: self()],
        mcp_providers: %{"app" => :handler}
      )

    open_session(ctx, [acp("App", "app")], "sess-nested")
    outer_id = agent_mcp(ctx, "app", "outer", "outer")
    assert_receive {:outer, outer}
    inner_id = agent_mcp(ctx, "app", "inner", "inner")
    assert_receive {:inner, _inner}
    send(outer, :release)

    assert %{"id" => ^inner_id, "result" => %{"result" => %{"inner" => true}}} = await_frame()
    assert %{"id" => ^outer_id, "result" => %{"result" => %{"nested" => true}}} = await_frame()
  end

  test "permission, file, and terminal callbacks run during a handler request" do
    ctx =
      boot(
        handler: McpHandler,
        handler_opts: [test_pid: self()],
        mcp_providers: %{"app" => :handler}
      )

    open_session(ctx, [acp("App", "app")], "sess-side")
    id = agent_mcp(ctx, "app", "slow", "block")
    assert_receive {:blocking, worker}

    permission_id =
      send_agent_request(ctx, "session/request_permission", %{
        "sessionId" => "sess-side",
        "toolCall" => %{"toolCallId" => "call-1"},
        "options" => [%{"optionId" => "reject", "name" => "Reject", "kind" => "reject_once"}]
      })

    file_id =
      send_agent_request(ctx, "fs/read_text_file", %{
        "sessionId" => "sess-side",
        "path" => "/tmp/note.txt"
      })

    terminal_id =
      send_agent_request(ctx, "terminal/create", %{
        "sessionId" => "sess-side",
        "command" => "echo"
      })

    assert_receive {:permission, _permission}
    assert_receive {:file_read, _file}
    assert_receive {:terminal, _terminal}
    assert_receive {:from_client, %{"id" => ^permission_id}}, 5_000

    assert_receive {:from_client, %{"id" => ^file_id, "result" => %{"content" => "contents"}}},
                   5_000

    assert_receive {:from_client, %{"id" => ^terminal_id}}, 5_000

    send(worker, :release)
    assert %{"id" => ^id, "result" => %{"result" => %{"released" => true}}} = await_frame()
  end

  test "a session update during a handler request is applied before that request returns" do
    ctx =
      boot(
        close: false,
        handler: McpHandler,
        handler_opts: [test_pid: self()],
        mcp_providers: %{"app" => :handler}
      )

    open_session(ctx, [acp("App", "app")], "sess-update")
    id = agent_mcp(ctx, "app", "c1", "count")
    assert_receive {:counting, 0, 0, worker}
    assert await_mcp_worker(ctx.client) == worker

    send_session_chunk(ctx, "sess-update")
    assert_receive {:session_updated, 1}

    monitor = Process.monitor(worker)
    assert :ok = Client.end_session(ctx.client, "sess-update")
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    refute_receive {:session_updated, _}
    assert_cancelled(await_frame(), id)

    next_id = agent_mcp(ctx, "app", "c2", "count")
    assert_unknown_server(await_frame(), next_id)
  end

  test "session updates hit the mailbox cap while a handler callback is running" do
    ctx =
      boot(
        handler: McpHandler,
        handler_opts: [test_pid: self(), block_updates: true],
        max_update_queue: 2
      )

    open_session(ctx, [], "sess-cap")
    send_session_chunk(ctx, "sess-cap")
    assert_receive {:update_blocking, pid}

    send_session_chunk(ctx, "sess-cap")
    send_session_chunk(ctx, "sess-cap")
    send_session_chunk(ctx, "sess-cap")
    await_handler_mailbox(ctx, 2)

    send(pid, :release_update)
    assert_receive {:session_updated, 1}
    assert_receive {:session_updated, 2}
    assert_receive {:session_updated, 3}
    refute_receive {:session_updated, _}
  end

  test "disconnect stops a blocked module provider and a blocked handler provider" do
    ctx =
      boot(
        mcp_providers: %{"tools" => BlockingProvider},
        handler_request_timeout: 60_000
      )

    open_session(ctx, [acp("Tools", "tools")], "sess-disc")
    _id = agent_mcp(ctx, "tools", "slow", "block")
    worker = await_mcp_worker(ctx.client)
    monitor = Process.monitor(worker)
    assert :ok = Client.disconnect(ctx.client)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

    ctx =
      boot(
        handler: McpHandler,
        handler_opts: [test_pid: self()],
        mcp_providers: %{"app" => :handler},
        handler_request_timeout: 60_000
      )

    open_session(ctx, [acp("App", "app")], "sess-disc-handler")
    _id = agent_mcp(ctx, "app", "slow", "block")
    assert_receive {:blocking, handler_worker}
    handler_monitor = Process.monitor(handler_worker)
    assert :ok = Client.disconnect(ctx.client)
    assert_receive {:DOWN, ^handler_monitor, :process, ^handler_worker, :killed}
  end

  test "disconnect does not start a handler callback waiting in the mailbox" do
    ctx =
      boot(
        handler: McpHandler,
        handler_opts: [test_pid: self(), block_updates: true],
        mcp_providers: %{"app" => :handler},
        handler_request_timeout: 60_000
      )

    open_session(ctx, [acp("App", "app")], "sess-queued")
    send_session_chunk(ctx, "sess-queued")
    assert_receive {:update_blocking, update_pid}

    _id = agent_mcp(ctx, "app", "queued", "tools/list")
    await_mcp_admitted(ctx)

    provider = provider_loop(self())
    :ok = Client.register_mcp_provider(ctx.client, "live", provider)
    live = Process.monitor(provider)

    assert :ok = Client.disconnect(ctx.client)
    send(update_pid, :release_update)
    refute_receive {:handler_mcp, _session_id, _request, _context}, 500
    refute_receive {:DOWN, ^live, :process, ^provider, _reason}
    assert Process.alive?(provider)
  end

  test "a queued provider does not start after its session closes" do
    ctx =
      boot(
        close: false,
        handler: McpHandler,
        handler_opts: [test_pid: self(), block_updates: true],
        mcp_providers: %{"app" => :handler},
        handler_request_timeout: 60_000
      )

    open_session(ctx, [acp("App", "app")], "sess-queued-close")
    send_session_chunk(ctx, "sess-queued-close")
    assert_receive {:update_blocking, update_pid}

    id = agent_mcp(ctx, "app", "queued-close", "tools/list")
    await_mcp_admitted(ctx)

    assert :ok = Client.end_session(ctx.client, "sess-queued-close")
    assert_cancelled(await_frame(), id)

    send(update_pid, :release_update)
    assert_receive {:session_updated, 1}
    refute_receive {:handler_mcp, _session_id, _request, _context}, 500
    refute Map.has_key?(:sys.get_state(ctx.client).sessions, "sess-queued-close")
  end

  test "a provider queued past its deadline cannot enter before timeout delivery" do
    ctx =
      boot(
        handler: McpHandler,
        handler_opts: [test_pid: self(), block_updates: true],
        mcp_providers: %{"app" => :handler},
        handler_request_timeout: 60_000
      )

    open_session(ctx, [acp("App", "app")], "sess-expired")
    send_session_chunk(ctx, "sess-expired")
    assert_receive {:update_blocking, update_pid}
    id = agent_mcp(ctx, "app", "expired", "inner")
    await_mcp_admitted(ctx)

    :sys.replace_state(ctx.client, fn state ->
      pending =
        Map.new(state.pending_agent_requests, fn {ref, request} ->
          {ref, Map.put(request, :deadline, System.monotonic_time(:millisecond) - 1)}
        end)

      %{state | pending_agent_requests: pending}
    end)

    send(update_pid, :release_update)
    assert_receive {:session_updated, 1}
    assert %{"id" => ^id, "error" => %{"message" => "MCP provider unavailable"}} = await_frame()
    refute_receive {:handler_mcp, _, _, _}
    assert :sys.get_state(ctx.client).pending_agent_requests == %{}
  end

  test "a queued provider does not start after its request is cancelled" do
    ctx =
      boot(
        handler: McpHandler,
        handler_opts: [test_pid: self(), block_updates: true],
        mcp_providers: %{"app" => :handler},
        handler_request_timeout: 60_000
      )

    open_session(ctx, [acp("App", "app")], "sess-queued-cancel")
    send_session_chunk(ctx, "sess-queued-cancel")
    assert_receive {:update_blocking, update_pid}

    id = agent_mcp(ctx, "app", "queued-cancel", "tools/list")
    await_mcp_admitted(ctx)

    send_json(ctx.outbound, Protocol.encode_cancel_request(id))
    assert_cancelled(await_frame(), id)

    send(update_pid, :release_update)
    assert_receive {:session_updated, 1}
    refute_receive {:handler_mcp, _session_id, _request, _context}, 500

    next_id = agent_mcp(ctx, "app", "queued-after", "tools/list")
    assert %{"id" => ^next_id, "result" => %{"result" => %{"tools" => []}}} = await_frame()
  end

  test "end_session during a load of a session that owns no ids does not reopen it" do
    provider = provider_loop(self())
    ctx = boot(close: false, mcp_providers: %{"tools" => provider})
    open_session(ctx, [])

    task =
      Task.async(fn ->
        Client.load_session(ctx.client, "sess-1", "/tmp", mcp_servers: [acp("Tools", "tools")])
      end)

    request = await_frame()
    assert request["method"] == "session/load"
    assert :ok = Client.end_session(ctx.client, "sess-1")
    send_result(ctx.outbound, request["id"], %{})

    assert {:error, {:invalid_params, :mcp_server_id_in_use}} = Task.await(task, 5_000)
    refute Map.has_key?(:sys.get_state(ctx.client).sessions, "sess-1")

    open_session(ctx, [acp("Tools", "tools")], "sess-2")
  end

  test "end_session during a load does not free a held server id" do
    provider = provider_loop(self())
    ctx = boot(close: false, mcp_providers: %{"tools" => provider})
    open_session(ctx, [acp("Tools", "tools")])

    task =
      Task.async(fn ->
        Client.load_session(ctx.client, "sess-1", "/tmp", mcp_servers: [acp("Tools", "tools")])
      end)

    request = await_frame()
    assert request["method"] == "session/load"
    assert :ok = Client.end_session(ctx.client, "sess-1")

    assert {:error, {:invalid_params, :mcp_server_id_in_use}} =
             Client.new_session(ctx.client, "/tmp",
               mcp_servers: [acp("Tools", "tools")],
               timeout: 2_000
             )

    refute_outbound(ctx)
    send_result(ctx.outbound, request["id"], %{})

    assert {:error, {:invalid_params, :mcp_server_id_in_use}} = Task.await(task, 5_000)

    open_session(ctx, [acp("Tools", "tools")], "sess-2")
  end

  test "a resume that starts after end_session is not failed by an earlier empty load" do
    provider = provider_loop(self())
    ctx = boot(close: false, mcp_providers: %{"fresh" => provider})
    open_session(ctx, [])

    task_a =
      Task.async(fn ->
        Client.load_session(ctx.client, "sess-1", "/tmp", mcp_servers: [])
      end)

    request_a = await_frame()
    assert request_a["method"] == "session/load"
    assert :ok = Client.end_session(ctx.client, "sess-1")

    task_b =
      Task.async(fn ->
        Client.resume_session(ctx.client, "sess-1", "/tmp", mcp_servers: [acp("Fresh", "fresh")])
      end)

    request_b = await_frame()
    assert request_b["method"] == "session/resume"
    send_result(ctx.outbound, request_b["id"], %{"sessionId" => "sess-1"})
    assert {:ok, %{"sessionId" => "sess-1"}} = Task.await(task_b, 5_000)

    send_result(ctx.outbound, request_a["id"], %{})
    assert {:error, {:invalid_params, :mcp_server_id_in_use}} = Task.await(task_a, 5_000)
    assert Map.has_key?(:sys.get_state(ctx.client).sessions, "sess-1")

    id = agent_mcp(ctx, "fresh", "ping", "tools/list")
    assert_receive {:provider, ref, _context, _params}
    send(provider, {:reply, ref, {:ok, %{"ok" => true}}})
    assert %{"id" => ^id, "result" => %{"result" => %{"ok" => true}}} = await_frame()
  end

  test "a close during a load answers a queued provider before the load finishes" do
    ctx =
      boot(
        close: false,
        handler: McpHandler,
        handler_opts: [test_pid: self(), block_updates: true],
        mcp_providers: %{"app" => :handler},
        handler_request_timeout: 60_000
      )

    open_session(ctx, [acp("App", "app")], "sess-hold")
    send_session_chunk(ctx, "sess-hold")
    assert_receive {:update_blocking, update_pid}

    task =
      Task.async(fn ->
        Client.load_session(ctx.client, "sess-hold", "/tmp", mcp_servers: [acp("App", "app")])
      end)

    request = await_frame()
    assert request["method"] == "session/load"

    id = agent_mcp(ctx, "app", "queued-hold", "tools/list")
    await_mcp_admitted(ctx)

    assert :ok = Client.end_session(ctx.client, "sess-hold")
    assert_cancelled(await_frame(), id)

    send(update_pid, :release_update)
    assert_receive {:session_updated, 1}
    refute_receive {:handler_mcp, _session_id, _request, _context}, 200

    send_result(ctx.outbound, request["id"], %{})
    assert {:error, {:invalid_params, :mcp_server_id_in_use}} = Task.await(task, 5_000)
    refute Map.has_key?(:sys.get_state(ctx.client).sessions, "sess-hold")
  end

  test "a close during a load drops a running provider result" do
    ctx =
      boot(
        close: false,
        handler: McpHandler,
        handler_opts: [test_pid: self()],
        mcp_providers: %{"app" => :handler},
        handler_request_timeout: 60_000
      )

    open_session(ctx, [acp("App", "app")], "sess-running")

    task =
      Task.async(fn ->
        Client.load_session(ctx.client, "sess-running", "/tmp", mcp_servers: [acp("App", "app")])
      end)

    request = await_frame()
    assert request["method"] == "session/load"

    id = agent_mcp(ctx, "app", "running", "block")
    assert_receive {:blocking, worker}
    assert is_pid(await_mcp_worker(ctx.client))

    assert :ok = Client.end_session(ctx.client, "sess-running")
    assert_cancelled(await_frame(), id)
    refute Process.alive?(worker)

    send(worker, :release)
    refute_receive {:from_client, %{"id" => ^id}}, 200

    send_result(ctx.outbound, request["id"], %{})
    assert {:error, {:invalid_params, :mcp_server_id_in_use}} = Task.await(task, 5_000)
  end

  test "a close during a load drops a pid provider result" do
    provider = provider_loop(self())

    ctx =
      boot(
        close: false,
        mcp_providers: %{"app" => provider},
        handler_request_timeout: 60_000
      )

    open_session(ctx, [acp("App", "app")], "sess-pid")

    task =
      Task.async(fn ->
        Client.load_session(ctx.client, "sess-pid", "/tmp", mcp_servers: [acp("App", "app")])
      end)

    request = await_frame()
    assert request["method"] == "session/load"

    id = agent_mcp(ctx, "app", "running-pid", "tools/list")
    assert_receive {:provider, ref, _context, _params}

    assert :ok = Client.end_session(ctx.client, "sess-pid")
    assert_cancelled(await_frame(), id)
    assert Process.alive?(provider)

    send(provider, {:reply, ref, {:ok, %{"late" => true}}})
    refute_receive {:from_client, %{"id" => ^id}}, 200

    send_result(ctx.outbound, request["id"], %{})
    assert {:error, {:invalid_params, :mcp_server_id_in_use}} = Task.await(task, 5_000)
  end

  test "end_session stays closed while an empty load is still in flight" do
    provider = provider_loop(self())
    ctx = boot(close: false, mcp_providers: %{"tools" => provider})
    open_session(ctx, [])

    task_a =
      Task.async(fn ->
        Client.load_session(ctx.client, "sess-1", "/tmp", mcp_servers: [acp("Tools", "tools")])
      end)

    request_a = await_frame()
    assert request_a["method"] == "session/load"

    task_b =
      Task.async(fn ->
        Client.load_session(ctx.client, "sess-1", "/tmp", mcp_servers: [])
      end)

    request_b = await_frame()
    assert request_b["method"] == "session/load"
    assert :ok = Client.end_session(ctx.client, "sess-1")

    send_result(ctx.outbound, request_a["id"], %{})
    assert {:error, {:invalid_params, :mcp_server_id_in_use}} = Task.await(task_a, 5_000)
    refute Map.has_key?(:sys.get_state(ctx.client).sessions, "sess-1")

    send_result(ctx.outbound, request_b["id"], %{})
    assert {:error, {:invalid_params, :mcp_server_id_in_use}} = Task.await(task_b, 5_000)
    refute Map.has_key?(:sys.get_state(ctx.client).sessions, "sess-1")

    open_session(ctx, [acp("Tools", "tools")], "sess-2")
  end

  defp start_quietly(opts) do
    parent = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(parent, {:started, Client.start_link(opts)})
    end)

    assert_receive {:started, result}, 5_000
    result
  end

  defp with_info_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp boot(opts \\ []) do
    {:ok, peer} = Memory.new_pair()
    parent = self()

    spawn_link(fn ->
      {:ok, transport} = Memory.connect(peer: peer, role: :agent)
      forward(transport, parent)
    end)

    {:ok, outbound} = Memory.connect(peer: peer, role: :agent)

    client_opts =
      [
        transport_mod: Memory,
        peer: peer,
        role: :client,
        handler: Keyword.get(opts, :handler, Arbor.ACP.Client.DefaultHandler),
        handler_opts: Keyword.get(opts, :handler_opts, []),
        initialize_timeout: 5_000,
        mcp_providers: Keyword.get(opts, :mcp_providers, %{})
      ]
      |> maybe_opt(opts, :max_pending_requests)
      |> maybe_opt(opts, :handler_request_timeout)
      |> maybe_opt(opts, :max_frame_bytes)
      |> maybe_opt(opts, :max_update_queue)

    parent = self()

    spawn_link(fn ->
      result = Client.start_link(client_opts)
      send(parent, {:booted, result})

      receive do
        :stop -> :ok
      end
    end)

    init = await_frame()
    assert init["method"] == "initialize"

    send_result(
      outbound,
      init["id"],
      agent_result(Keyword.get(opts, :advertise, true), Keyword.get(opts, :close, true))
    )

    assert_receive {:booted, {:ok, client}}, 5_000
    %{client: client, outbound: outbound, peer: peer}
  end

  defp maybe_opt(opts, source, key) do
    case Keyword.fetch(source, key) do
      {:ok, value} -> Keyword.put(opts, key, value)
      :error -> opts
    end
  end

  defp agent_result(advertise, close?) do
    session = %{"resume" => %{}, "delete" => %{}, "fork" => %{}}
    session = if close?, do: Map.put(session, "close", %{}), else: session

    caps = %{"loadSession" => true, "sessionCapabilities" => session}

    caps =
      case advertise do
        false -> Map.put(caps, "mcpCapabilities", %{"acp" => false})
        :object -> Map.put(caps, "mcpCapabilities", %{"acp" => %{}})
        :omit -> caps
        true -> Map.put(caps, "mcpCapabilities", %{"acp" => true})
      end

    %{"protocolVersion" => 1, "agentCapabilities" => caps}
  end

  defp open_session(ctx, servers, session_id \\ "sess-1") do
    task = Task.async(fn -> Client.new_session(ctx.client, "/tmp", mcp_servers: servers) end)
    request = await_frame()
    assert request["method"] == "session/new"
    send_result(ctx.outbound, request["id"], %{"sessionId" => session_id})
    assert {:ok, %{"sessionId" => ^session_id}} = Task.await(task, 5_000)
    request
  end

  defp agent_mcp(ctx, server_id, request_id, method, params \\ nil) do
    message =
      Protocol.encode_mcp_message_request(server_id, request_id, method,
        params: params,
        id: System.unique_integer([:positive])
      )

    send_json(ctx.outbound, message)
    message["id"]
  end

  defp assert_mcp_result(ctx, provider, method, result) do
    id = agent_mcp(ctx, "tools", method, method)
    assert_receive {:provider, ref, _context, _params}
    send(provider, {:reply, ref, {:ok, result}})
    response = await_frame()
    assert response["id"] == id
    assert response["result"]["result"] == result
  end

  defp assert_provider_unavailable(response, id) do
    assert response["id"] == id
    assert response["error"]["code"] == -32_603
    assert response["error"]["message"] == "MCP provider unavailable"
  end

  defp assert_unknown_server(response, id) do
    assert response["id"] == id
    assert response["error"]["code"] == -32_602
    assert response["error"]["message"] == "Unknown MCP server"
  end

  defp assert_cancelled(response, id) do
    assert response["id"] == id
    assert response["error"]["code"] == -32_800
    assert response["error"]["message"] == "Request cancelled"
  end

  defp await_frame do
    assert_receive {:from_client, message}, 5_000
    message
  end

  defp send_session_chunk(ctx, session_id) do
    send_json(ctx.outbound, %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "hi"}
        }
      }
    })
  end

  # The memory peer hands a frame to the client receiver before `send_json/2`
  # returns. The receiver is parked on the next read only after the client
  # has acked that frame, so this waits out that handoff.
  defp await_mcp_admitted(ctx, attempts \\ 40) do
    client = :sys.get_state(ctx.client)

    pending =
      Enum.count(client.pending_agent_requests, fn {_ref, request} ->
        request.kind == :mcp
      end)

    # The runner is blocked inside the session-update callback, so a system
    # call would wait behind that receive. The cast is visible in its mailbox.
    queued = queue_len(client.handler_pid)

    cond do
      pending == 1 and queued >= 1 ->
        :ok

      attempts > 0 ->
        receive do
        after
          20 -> await_mcp_admitted(ctx, attempts - 1)
        end

      true ->
        flunk("handler request was not waiting to start (pending=#{pending}, queued=#{queued})")
    end
  end

  defp await_handler_mailbox(ctx, length, attempts \\ 40) do
    client = :sys.get_state(ctx.client)
    peer = :sys.get_state(ctx.peer)
    parked? = not :queue.is_empty(peer.waiters.client)
    queued = queue_len(client.handler_pid)

    if parked? and queue_len(ctx.client) == 0 and queued == length do
      :ok
    else
      if attempts > 0 do
        receive do
        after
          20 -> await_handler_mailbox(ctx, length, attempts - 1)
        end
      else
        flunk("handler mailbox did not settle at #{length} (queued=#{queued})")
      end
    end
  end

  defp handler_runner(ctx) do
    :sys.get_state(:sys.get_state(ctx.client).handler_pid)
  end

  # One id source. Protocol.encode_* draws from a different counter and can
  # reuse an id this test already gave an in-flight `mcp/message`.
  defp send_agent_request(ctx, method, params) do
    id = System.unique_integer([:positive])

    send_json(ctx.outbound, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })

    id
  end

  defp queue_len(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, length} -> length
      _dead -> 0
    end
  end

  defp await_mcp_worker(client, attempts \\ 15) do
    pending = :sys.get_state(client).pending_agent_requests

    case Enum.find_value(pending, fn {_ref, request} ->
           if request.kind == :mcp, do: Map.get(request, :worker)
         end) do
      pid when is_pid(pid) ->
        pid

      _missing when attempts > 0 ->
        receive do
        after
          20 -> await_mcp_worker(client, attempts - 1)
        end

      _missing ->
        nil
    end
  end

  defp send_result(outbound, id, result) do
    send_json(outbound, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp send_error(outbound, id, code, message) do
    send_json(outbound, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp send_json(outbound, message) do
    {:ok, _state} = Memory.send_message(Jason.encode!(message), outbound)
    :ok
  end

  defp refute_outbound(ctx) do
    assert :queue.is_empty(:sys.get_state(ctx.peer).queues.agent)
    refute_received {:from_client, _}
  end

  defp forward(transport, parent) do
    case Memory.receive_message(transport) do
      {:ok, raw, transport} ->
        send(parent, {:from_client, Jason.decode!(raw)})
        forward(transport, parent)

      {:error, _reason} ->
        :ok
    end
  end

  defp provider_loop(parent) do
    spawn(fn -> provider_loop(parent, nil) end)
  end

  defp provider_loop(parent, _acc) do
    receive do
      {:acp_mcp_request, ref, context, params} ->
        send(parent, {:provider, ref, context, params})

        receive do
          {:reply, ^ref, outcome} ->
            send(context.client, {:acp_mcp_provider_result, ref, outcome})
        end

        provider_loop(parent, nil)
    end
  end

  defp acp(name, id), do: Types.acp_mcp_server(name, id)
  defp stdio, do: Types.stdio_mcp_server("Local", "echo")
  defp http, do: Types.http_mcp_server("Web", "https://example.com/mcp")
  defp sse, do: Types.sse_mcp_server("Events", "https://example.com/sse")
end
