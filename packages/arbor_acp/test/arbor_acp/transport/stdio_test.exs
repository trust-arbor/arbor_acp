defmodule Arbor.ACP.Transport.StdioTest do
  use ExUnit.Case, async: false
  alias Arbor.ACP.Transport.Stdio
  alias Arbor.RPC.Subprocess

  test "temporary readers and opening tasks do not acquire child ownership" do
    owner = self()
    task = Task.async(fn -> Stdio.connect(command: ["sh", "-c", "exec cat"], owner: owner) end)
    assert {:ok, state} = Task.await(task)
    assert {:ok, state} = Stdio.send_message("{}", state)
    reader = Task.async(fn -> Stdio.receive_message(state, 500) end)
    assert {:ok, "{}", state} = Task.await(reader)
    assert Stdio.connected?(state)
    assert {:ok, state} = Stdio.send_message("[]", state)
    assert {:ok, "[]", state} = Stdio.receive_message(state, 500)
    [actor] = Stdio.linked_processes(state)
    monitor = Process.monitor(actor)
    assert :ok = Stdio.close(state)
    assert_receive {:DOWN, ^monitor, :process, ^actor, :normal}, 500
    assert :ok = Stdio.close(state)
  end

  test "per-frame limit excludes LF and accepts several frames in one native chunk" do
    state = child("printf '{}\\n{}\\n'; sleep 1", max_frame_bytes: 2)
    eventually(fn -> Subprocess.stats!(state.subprocess).frames == 2 end)
    assert {:ok, "{}", state} = Stdio.receive_message(state, 0)
    assert {:ok, "{}", state} = Stdio.receive_message(state, 0)
    assert {:error, :handshake_timeout} = Stdio.receive_message(state, 0)
    assert {:ok, _} = Stdio.send_message("{}", state)
    assert {:error, :frame_too_large} = Stdio.send_message("{ }", state)
  end

  test "banner and BOM policy stays in the protocol wrapper" do
    state = child("printf 'banner\\n\\357\\273\\277  {\"ok\":true}  \\n'; sleep 1")
    assert {:ok, ~s({"ok":true}), _} = Stdio.receive_message(state, 500)
    assert {:error, {:validation_error, :embedded_newline}} = Stdio.send_message("{}\r", state)
    assert {:error, {:validation_error, :invalid_json}} = Stdio.send_message("{bad", state)
  end

  test "slow partial output does not renew the total read deadline" do
    state = child("printf '{\"ok\"'; sleep 0.15; printf ':true}\\n'; sleep 1")
    assert {:error, :handshake_timeout} = Stdio.receive_message(state, 30)
    assert {:ok, ~s({"ok":true}), _} = Stdio.receive_message(state, 500)
  end

  test "unfinished byte overflow and invalid UTF8 close explicitly" do
    state = child("printf '12345'; sleep 1", max_frame_bytes: 4)
    assert {:error, {:connection_error, :frame_too_large}} = Stdio.receive_message(state, 500)
    refute Stdio.connected?(state)

    state = child("printf '\\377\\n'; sleep 1")
    assert {:error, :invalid_utf8} = Stdio.receive_message(state, 500)
    refute Stdio.connected?(state)
  end

  test "effective child PATH cannot fall back to the host executable search" do
    assert {:error, {:connection_error, {:spawn_failed, {:executable_not_found, "sh"}}}} =
             Stdio.connect(command: ["sh"], env: %{"PATH" => false})

    assert {:error, {:invalid_process_group, :invalid}} =
             Stdio.connect(command: ["sh"], process_group: :invalid)
  end

  test "push delivery is direct generation-matched credit with explicit ACK" do
    state = child("printf '{}\\n[]\\n'; sleep 1")
    assert {:ok, state} = Stdio.subscribe(self(), state)
    generation = Stdio.identity(state)
    assert_receive {:arbor_rpc, ^generation, {:frame, token, "{}"}} = message, 500
    assert {:frame, ^token, "{}"} = Stdio.event(state, message)
    assert :ignore = Stdio.event(state, {:arbor_rpc, make_ref(), {:frame, token, "stale"}})
    refute_receive {:arbor_rpc, ^generation, {:frame, _, _}}, 30
    assert :ok = Stdio.ack(state, token)
    assert_receive {:arbor_rpc, ^generation, {:frame, token, "[]"}}, 500
    assert :ok = Stdio.ack(state, token)
  end

  defp child(script, opts \\ []) do
    {:ok, state} = Stdio.connect([command: ["sh", "-c", script]] ++ opts)
    on_exit(fn -> Stdio.close(state) end)
    state
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
