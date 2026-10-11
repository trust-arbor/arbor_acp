defmodule Arbor.ACP.ExtensionsTest do
  use ExUnit.Case, async: true
  alias Arbor.ACP.{Agent, Client}
  alias Arbor.ACP.Agent.Transport.Memory

  defmodule AgentHandler do
    @behaviour Arbor.ACP.Agent.Handler
    def init(opts), do: {:ok, Keyword.fetch!(opts, :parent)}

    def handle_new_session(params, _, state) do
      send(state, {:new_params, params})
      {:reply, %{"sessionId" => "extension-session"}, state}
    end

    def handle_prompt(_, _, _, state), do: {:reply, %{"stopReason" => "end_turn"}, state}

    def handle_extension_request("_fail", _, _, state),
      do:
        {:error,
         %{"code" => -32055, "message" => "native error", "data" => [1, nil], "future" => true},
         state}

    def handle_extension_request("_wait", _, _, state) do
      send(state, {:waiting, self()})

      receive do
        :finish -> {:reply, %{}, state}
      end
    end

    def handle_extension_request(_, params, _, state), do: {:reply, params, state}

    def handle_extension_notification(method, params, _, state) do
      send(state, {:agent_notification, method, params})
      {:ok, state}
    end
  end

  defmodule ClientHandler do
    @behaviour Arbor.ACP.Client.Handler
    def init(opts), do: {:ok, Keyword.fetch!(opts, :parent)}
    def handle_session_update(_, _, state), do: {:ok, state}
    def handle_permission_request(_, _, _, state), do: {:ok, %{"outcome" => "cancelled"}, state}

    def handle_extension_request("_fail", _, state),
      do:
        {:error,
         %{"code" => -32056, "message" => "client error", "data" => false, "future" => []}, state}

    def handle_extension_request("_wait", _, state) do
      send(state, {:client_waiting, self()})

      receive do
        :finish -> {:ok, %{}, state}
      end
    end

    def handle_extension_request(_, params, state), do: {:ok, params, state}

    def handle_extension_notification(method, params, state) do
      send(state, {:client_notification, method, params})
      {:ok, state}
    end
  end

  defp pair(client_opts \\ [], agent_opts \\ []) do
    {:ok, peer} = Memory.new_pair()

    {:ok, agent} =
      Agent.start_link(
        Keyword.merge(
          [
            handler: AgentHandler,
            handler_opts: [parent: self()],
            transport: {:memory, peer}
          ],
          agent_opts
        )
      )

    {:ok, client} =
      Client.start_link(
        Keyword.merge(
          [
            handler: ClientHandler,
            handler_opts: [parent: self()],
            transport_mod: Memory,
            peer: peer,
            role: :client
          ],
          client_opts
        )
      )

    Process.unlink(client)
    Process.unlink(agent)

    on_exit(fn ->
      for {pid, stop} <- [
            {agent, fn -> Agent.stop(agent) end},
            {client, fn -> Client.stop(client) end}
          ] do
        monitor = Process.monitor(pid)

        try do
          if Process.alive?(pid), do: stop.()
        catch
          :exit, _already_stopping -> :ok
        end

        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1000
      end
    end)

    {client, agent}
  end

  test "bidirectional extension requests preserve JSON values and complete errors" do
    {client, agent} = pair()
    value = %{"nested" => [1, true, nil, %{"future" => "value"}]}
    assert {:ok, ^value} = Client.extension_request(client, "_vendor/new-method", value)
    assert {:ok, ^value} = Agent.extension_request(agent, "_vendor/new-method", value)

    assert {:error, %{"code" => -32055, "data" => [1, nil], "future" => true}} =
             Client.extension_request(client, "_fail", %{})

    assert {:error, %{"code" => -32056, "data" => false, "future" => []}} =
             Agent.extension_request(agent, "_fail", %{})
  end

  test "bidirectional notifications, filtering and unsubscribe" do
    {client, agent} = pair()
    assert :ok = Client.subscribe_extensions(client, self(), methods: ["_selected"])
    assert :ok = Client.extension_notify(client, "_client", %{"extra" => true})
    assert_receive {:agent_notification, "_client", %{"extra" => true}}
    assert :ok = Agent.extension_notify(agent, "_ignored", %{})
    assert_receive {:client_notification, "_ignored", %{}}
    refute_receive {:acp_extension_notification, "_ignored", _}
    assert :ok = Agent.extension_notify(agent, "_selected", %{"raw" => [nil]})
    assert_receive {:acp_extension_notification, "_selected", %{"raw" => [nil]}}
    assert :ok = Client.unsubscribe_extensions(client)
    assert :ok = Agent.extension_notify(agent, "_selected", %{})
    refute_receive {:acp_extension_notification, _, _}
  end

  test "rejects standard method names and non-JSON parameters before dispatch" do
    {client, agent} = pair()
    assert {:error, _} = Client.extension_request(client, "session/new", %{})
    assert {:error, _} = Agent.extension_notify(agent, "_", %{})
    assert {:error, _} = Client.extension_request(client, "_test", %{atom_key: 1})
    assert {:error, _} = Client.extension_notify(client, "_test", %{"pid" => self()})
    assert :ready = Client.status!(client)
  end

  test "extension requests use pending deadlines and ignore late handler results" do
    {client, agent} = pair([pending_request_timeout: 40], handler_request_timeout: 200)
    task = Task.async(fn -> Client.extension_request(client, "_wait", %{}) end)
    assert_receive {:waiting, handler}
    assert {:error, :request_timeout} = Task.await(task)
    assert :sys.get_state(client).pending_requests == %{}
    send(handler, :finish)
    assert {:ok, %{}} = Client.extension_request(client, "_echo", %{})

    assert {:error, %{"message" => "Client handler timed out"}} =
             timed_out_client_request(client, agent)
  end

  defp timed_out_client_request(client, agent) do
    :sys.replace_state(client, &%{&1 | handler_request_timeout: 40})
    task = Task.async(fn -> Agent.extension_request(agent, "_wait", %{}) end)
    assert_receive {:client_waiting, handler}
    result = Task.await(task)
    send(handler, :finish)
    result
  end

  test "slow extension subscribers close the connection at the byte limit" do
    {client, agent} = pair(max_update_queue_bytes: 512)

    sink =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = Client.subscribe_extensions(client, sink)

    assert :ok =
             Agent.extension_notify(agent, "_large", %{"value" => String.duplicate("x", 1024)})

    for _ <- 1..100, Client.status!(client) != :disconnected, do: Process.sleep(1)
    assert :disconnected = Client.status!(client)
    assert {:message_queue_len, 0} = Process.info(sink, :message_queue_len)
    send(sink, :stop)
  end

  test "session metadata survives ordinary client encoding" do
    {client, _} = pair()
    meta = %{"vendor" => %{"future" => true}}
    assert {:ok, _} = Client.new_session(client, "/tmp", meta: meta)
    assert_receive {:new_params, %{"_meta" => ^meta}}
  end
end
