defmodule Arbor.ACP.PublicContractTest do
  use ExUnit.Case, async: true
  alias Arbor.ACP.{Agent, Client}

  defmodule SlowPeer do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    @impl true
    def init(owner), do: {:ok, owner}
    @impl true
    def handle_call(request, _from, owner) do
      send(owner, {:pending, request})
      {:noreply, owner}
    end
  end

  defmodule CleanupTransport do
    def close({owner, result}) do
      send(owner, :transport_closed)
      result
    end
  end

  defmodule StoppingPeer do
    use GenServer
    def start_link(reason), do: GenServer.start_link(__MODULE__, reason)
    @impl true
    def init(reason), do: {:ok, reason}
    @impl true
    def handle_call(:status, _from, reason), do: {:stop, reason, reason}
  end

  test "status reports normal shutdown racing a query as unavailable" do
    for reason <- [:normal, :shutdown, {:shutdown, :finished}] do
      client = start_supervised!({StoppingPeer, reason}, id: make_ref())
      assert {:error, :client_not_alive} = Client.status(client)
    end
  end

  test "status is tagged and bang inspection is explicit" do
    client = start_supervised!({Client, _skip_connect: true})
    assert {:ok, :ready} = Client.status(client)
    assert Client.status!(client) == :ready
    assert :ok = Client.disconnect(client)
    assert Process.alive?(client)
    assert {:ok, :disconnected} = Client.status(client)
    assert :ok = Client.stop(client)
    assert {:error, :client_not_alive} = Client.status(client)
    assert_raise RuntimeError, fn -> Client.status!(client) end
    assert :ok = Client.stop(client)
  end

  test "setters use an explicit caller wait without claiming remote cancellation" do
    client = start_supervised!({SlowPeer, self()})
    assert {:error, :timeout} = Client.set_mode(client, "s", "m", timeout: 1)
    assert_receive {:pending, {:set_mode, "s", "m"}}
    assert {:error, :timeout} = Client.set_model(client, "s", "model", timeout: 1)
    assert_receive {:pending, {:set_model, "s", "model"}}
    assert {:error, :timeout} = Client.set_config_option(client, "s", "config", false, timeout: 1)
    assert_receive {:pending, {:set_config_option, "s", "config", false}}
    assert {:error, :timeout} = Agent.status(client, timeout: 1)
    assert Process.alive?(client)
    assert_raise ArgumentError, fn -> Client.set_mode(client, "s", "m", timeuot: 1) end
  end

  test "stop confirms client and handler death after transport cleanup" do
    client = start_supervised!({Client, _skip_connect: true})
    owner = self()

    state =
      :sys.replace_state(
        client,
        &%{&1 | transport_mod: CleanupTransport, transport_state: {owner, :ok}}
      )

    handler = state.handler_pid
    assert :ok = Client.stop(client, :normal, timeout: 1_000)
    assert_receive :transport_closed
    refute Process.alive?(client)
    refute Process.alive?(handler)
  end

  test "cleanup failure is reported even when the client terminates" do
    client = start_supervised!({Client, _skip_connect: true})
    owner = self()

    :sys.replace_state(
      client,
      &%{
        &1
        | transport_mod: CleanupTransport,
          transport_state: {owner, {:error, :cleanup_unconfirmed}}
      }
    )

    assert {:error, :cleanup_unconfirmed} = Client.stop(client)
    assert_receive :transport_closed
  end

  test "stop uses a finite caller budget and does not kill a stalled peer" do
    client = start_supervised!({SlowPeer, self()})
    assert {:error, :timeout} = Client.stop(client, :normal, timeout: 1)
    assert_receive {:pending, {:stop, :normal}}
    assert Process.alive?(client)
    assert_raise ArgumentError, fn -> Client.stop(client, :normal, timeout: :infinity) end
    assert_raise ArgumentError, fn -> Agent.stop(client, timeout: :infinity) end
  end
end
