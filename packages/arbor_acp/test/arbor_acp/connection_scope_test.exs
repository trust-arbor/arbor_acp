defmodule Arbor.ACP.Client.ConnectionScopeTest do
  use ExUnit.Case, async: false
  alias Arbor.ACP.Client
  alias Arbor.ACP.Transport.Stdio
  alias Arbor.RPC.Subprocess

  defmodule BlockingHandler do
    @behaviour Arbor.ACP.Client.Handler
    def handle_session_update(_sid, _update, state), do: {:ok, state}

    def handle_permission_request(_sid, _call, _options, state),
      do: {:ok, %{"outcome" => "cancelled"}, state}

    def init(opts) do
      send(Keyword.fetch!(opts, :owner), {:handler_initializing, self()})

      receive do
        :continue -> {:ok, %{}}
      end
    end
  end

  defmodule FailedClose do
    def close(%{native: native}) do
      :ok = Stdio.close(native)
      {:error, :fixture_cleanup_failed}
    end
  end

  defmodule BlockingTermination do
    @behaviour Arbor.ACP.Client.Handler
    def init(opts), do: {:ok, Keyword.fetch!(opts, :owner)}
    def handle_session_update(_sid, _update, state), do: {:ok, state}

    def handle_permission_request(_sid, _call, _options, state),
      do: {:ok, %{"outcome" => "cancelled"}, state}

    def terminate(_reason, owner) do
      send(owner, {:handler_terminating, self()})

      receive do
        :continue -> :ok
      end
    end
  end

  test "callback runs in its caller and native processes are reaped before success" do
    owner = self()

    assert {:ok, :value} =
             Client.with_connection(opts(), fn client ->
               assert self() == owner
               assert {:ok, :ready} = Client.status(client)
               send(owner, {:resources, resources(client)})
               :value
             end)

    assert_receive {:resources, resources}
    assert_closed(resources)
  end

  test "exceptions and throws retain their original outcome after cleanup" do
    owner = self()

    assert_raise RuntimeError, "callback failure", fn ->
      Client.with_connection(opts(), fn client ->
        send(owner, {:resources, resources(client)})
        raise "callback failure"
      end)
    end

    assert_receive {:resources, resources}
    assert_closed(resources)
    assert catch_throw(Client.with_connection(opts(), fn _ -> throw(:original) end)) == :original
  end

  test "abrupt caller death still closes the native child and client resources" do
    owner = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        Client.with_connection(opts(), fn client ->
          send(owner, {:resources, resources(client)})

          receive do
            :never -> :ok
          end
        end)
      end)

    assert_receive {:resources, resources}, 2_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}

    for pid <- resources.pids do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    end

    assert_closed(resources)
  end

  test "startup cutoff reaps a handler blocked in init" do
    owner = self()

    task =
      Task.async(fn ->
        Client.with_connection(
          opts() ++ [handler: BlockingHandler, handler_opts: [owner: owner]],
          [establish_timeout: 100, cleanup_timeout: 500],
          fn _ -> flunk("not initialized") end
        )
      end)

    assert_receive {:handler_initializing, handler}, 500
    ref = Process.monitor(handler)
    assert {:error, _reason} = Task.await(task, 1_500)
    assert_receive {:DOWN, ^ref, :process, ^handler, _}, 500
  end

  test "a cleanup failure remains visible after the callback stops its client" do
    assert {:error, {:cleanup_failed, :fixture_cleanup_failed, :retained}} =
             Client.with_connection(opts(), fn client ->
               state = :sys.get_state(client)

               :sys.replace_state(
                 client,
                 &%{
                   &1
                   | transport_mod: FailedClose,
                     transport_state: %{native: state.transport_state}
                 }
               )

               assert {:error, :fixture_cleanup_failed} = Client.stop(client)
               :retained
             end)
  end

  test "a conflicting registered name does not adopt or stop the existing client" do
    client = start_supervised!({Client, [name: :acp_scope_existing, _skip_connect: true]})

    assert {:error, {:already_started, ^client}} =
             Client.with_connection(opts() ++ [name: :acp_scope_existing], fn _ ->
               flunk("borrowed")
             end)

    assert Process.alive?(client)
  end

  test "cleanup cutoff retires a blocked handler and retains the callback value" do
    owner = self()

    assert {:error, {:cleanup_failed, _reason, :retained}} =
             Client.with_connection(
               opts() ++ [handler: BlockingTermination, handler_opts: [owner: owner]],
               [cleanup_timeout: 500],
               fn client ->
                 send(owner, {:resources, resources(client)})
                 :retained
               end
             )

    assert_receive {:handler_terminating, handler}
    assert_receive {:resources, resources}
    ref = Process.monitor(handler)
    assert_receive {:DOWN, ^ref, :process, ^handler, _}, 500
    assert_closed(resources)
  end

  test "guardian failure retains a successful callback value and the client closes" do
    owner = self()

    assert {:error, {:cleanup_failed, :connection_scope_closed, :retained}} =
             Client.with_connection(opts(), fn client ->
               state = :sys.get_state(client)
               {guardian, _token, _deadline} = state.connection_scope
               send(owner, {:resources, resources(client)})
               monitor = Process.monitor(client)
               Process.exit(guardian, :kill)
               assert_receive {:DOWN, ^monitor, :process, ^client, _}, 2_000
               :retained
             end)

    assert_receive {:resources, resources}
    assert_closed(resources)
  end

  test "invalid ownership and infinite budgets fail before construction" do
    for scope_opts <- [[establish_timeout: :infinity], [cleanup_timeout: 0]] do
      assert_raise ArgumentError, fn ->
        Client.with_connection(opts(), scope_opts, fn _ -> :ok end)
      end
    end

    assert_raise ArgumentError, fn ->
      Client.with_connection(opts() ++ [owner: self()], fn _ -> :ok end)
    end
  end

  defp resources(client) do
    state = :sys.get_state(client)
    [actor] = Stdio.linked_processes(state.transport_state)

    %{
      pids: [client, state.handler_pid, state.receiver_pid, actor],
      handle: state.transport_state.subprocess
    }
  end

  defp assert_closed(resources) do
    assert Enum.all?(resources.pids, &(not Process.alive?(&1)))
    assert :ok = Subprocess.close(resources.handle)
  end

  defp opts do
    script = """
    read line
    id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([^,}]*\\).*/\\1/p')
    printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentInfo":{"name":"fixture","version":"1"},"agentCapabilities":{}}}\\n' "$id"
    exec sleep 30
    """

    [command: ["sh", "-c", script], initialize_timeout: 1_000]
  end
end
