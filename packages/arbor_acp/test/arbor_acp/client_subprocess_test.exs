defmodule Arbor.ACP.Client.SubprocessTest do
  use ExUnit.Case, async: false
  alias Arbor.ACP.Client
  alias Arbor.ACP.AdapterTransport
  alias Arbor.ACP.Transport.Stdio

  defmodule CleanupFailureTransport do
    @behaviour Arbor.ACP.Transport
    def connect(_opts), do: {:ok, %{}}
    def send_message(_message, state), do: {:ok, state}
    def receive_message(_state), do: {:error, :closed}
    def close(%{close_result: :raise}), do: raise("cleanup failed")
    def close(%{close_result: result}), do: result
    def close(_state), do: {:error, :cleanup_timeout}
  end

  defmodule CloseProbe do
    use GenServer
    def init(result), do: {:ok, result}
    def handle_call(:close, _from, :no_confirmation), do: {:stop, :normal, :no_confirmation}
    def handle_call(:close, _from, result), do: {:stop, :normal, result, result}
  end

  defmodule InitClosedTransport do
    @behaviour Arbor.ACP.Transport
    def connect(_opts), do: {:ok, %{}}

    def send_message(_message, state) do
      send(self(), {:transport_closed, {:cleanup_failed, :closed, {:error, :cleanup_timeout}}})
      {:ok, state}
    end

    def receive_message(_state) do
      receive do
        :stop -> {:error, :closed}
      end
    end

    def close(_state), do: :ok
  end

  test "initialize closure preserves known cleanup failure after idempotent close" do
    result =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        Client.start_link(transport_mod: InitClosedTransport, initialize_timeout: 500)
      end)
      |> Task.await(1000)

    assert {:error, {:transport_closed, {:cleanup_failed, :closed, {:error, :cleanup_timeout}}}} =
             result
  end

  test "adapter transport close preserves known failure and unconfirmed caller exit" do
    {:ok, bridge} = GenServer.start(CloseProbe, {:error, :cleanup_timeout})
    assert {:error, :cleanup_timeout} = AdapterTransport.close(%AdapterTransport{bridge: bridge})
    assert :ok = AdapterTransport.close(%AdapterTransport{bridge: bridge})

    {:ok, bridge} = GenServer.start(CloseProbe, :no_confirmation)

    assert {:error, {:close_failed, _reason}} =
             AdapterTransport.close(%AdapterTransport{bridge: bridge})
  end

  test "native initialize and disconnect use the shared actor lifetime" do
    client = client()
    state = :sys.get_state(client)
    [actor] = Stdio.linked_processes(state.transport_state)
    monitor = Process.monitor(actor)
    assert state.agent_info["name"] == "fixture"
    assert :ok = Client.disconnect(client)
    assert_receive {:DOWN, ^monitor, :process, ^actor, :normal}, 500
    assert :ok = Client.disconnect(client)
    refute Process.alive?(state.receiver_pid)
  end

  test "abrupt shared actor death promptly fails pending requests" do
    client = client()
    state = :sys.get_state(client)
    [actor] = Stdio.linked_processes(state.transport_state)
    pending = Task.async(fn -> Client.new_session(client, File.cwd!()) end)
    eventually(fn -> map_size(:sys.get_state(client).pending_requests) == 1 end)
    Process.exit(actor, :kill)
    assert {:error, reason} = Task.await(pending, 1000)

    assert reason in [
             :transport_closed,
             :receiver_exited,
             {:transport_error, {:actor_down, :killed}}
           ]

    assert :sys.get_state(client).status == :disconnected
  end

  test "terminal cleanup errors remain visible after ordinary actor termination" do
    for kind <- [:transport_error, :transport_closed] do
      client = client()

      send(
        client,
        {kind,
         {:connection_error, {:cleanup_failed, {:process_exited, 0}, {:error, :cleanup_timeout}}}}
      )

      eventually(fn -> :sys.get_state(client).status == :disconnected end)
      assert {:error, :cleanup_timeout} = Client.disconnect(client)
      assert {:error, :cleanup_timeout} = Client.disconnect(client)
    end
  end

  test "explicit disconnect propagates custom transport cleanup failure" do
    client =
      start_supervised!({Client, [transport_mod: CleanupFailureTransport, _skip_connect: true]},
        id: make_ref()
      )

    :sys.replace_state(client, &%{&1 | transport_state: %{}, status: :ready})
    assert {:error, :cleanup_timeout} = Client.disconnect(client)
    assert {:error, :cleanup_timeout} = Client.disconnect(client)
  end

  test "invalid custom close returns and exceptions cannot claim cleanup success" do
    for result <- [nil, :raise] do
      client =
        start_supervised!({Client, [transport_mod: CleanupFailureTransport, _skip_connect: true]},
          id: make_ref()
        )

      :sys.replace_state(
        client,
        &%{&1 | transport_state: %{close_result: result}, status: :ready}
      )

      assert {:error, error} = Client.disconnect(client)

      case result do
        nil -> assert match?({:invalid_close_result, _}, error)
        :raise -> assert match?({:close_failed, :error, %RuntimeError{}}, error)
      end
    end
  end

  defp client do
    script = """
    read line
    id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([^,}]*\\).*/\\1/p')
    printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentInfo":{"name":"fixture","version":"1"},"agentCapabilities":{}}}\\n' "$id"
    exec sleep 30
    """

    start_supervised!({Client, [command: ["sh", "-c", script], initialize_timeout: 1000]},
      id: make_ref()
    )
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, attempts - 1)
        )
  end

  defp eventually(_fun, 0), do: flunk("condition did not become true")
end
