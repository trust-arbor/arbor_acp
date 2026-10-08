defmodule Arbor.ACP.Adapters.Pi.SubprocessTest do
  use ExUnit.Case, async: false

  alias Arbor.ACP.AdapterSupport.Subprocess, as: PortRunner
  alias Arbor.ACP.Adapters.Internal.PromptQueue
  alias Arbor.ACP.Adapters.Pi
  alias Arbor.RPC.Subprocess

  @moduletag timeout: 10_000

  test "known cleanup failure surfaces through shutdown and prevents replacement or deletion" do
    for method <- [:shutdown, "session/close", "session/delete", "session/new"] do
      state = child("exec /bin/sleep 30", cleanup_timeout: 150, term_grace: 50)
      port = state.port
      pid = Subprocess.os_pid(port)
      [actor] = Subprocess.linked_processes(port)
      monitor = Process.monitor(actor)

      # Exercise failure propagation with a real owned actor and opaque handle.
      :sys.replace_state(actor, fn state ->
        %{
          state
          | closed: {:cleanup_failed, :closed, {:error, :cleanup_timeout}},
            cleanup_result: {:error, :cleanup_timeout}
        }
      end)

      result =
        if method == :shutdown do
          Pi.shutdown(state)
        else
          Pi.translate_outbound(
            %{
              "method" => method,
              "id" => 50,
              "params" => %{"sessionId" => "s1", "cwd" => File.cwd!()}
            },
            state
          )
        end

      expected = if method == :shutdown, do: :cleanup_timeout, else: ":cleanup_timeout"
      assert {:error, ^expected, state} = result
      assert state.port == nil
      assert state.cleanup_result == {:error, :cleanup_timeout}
      assert_receive {:DOWN, ^monitor, :process, ^actor, :normal}

      eventually(fn ->
        {_output, status} =
          System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

        status != 0
      end)
    end
  end

  test "terminal cleanup failure survives an already-stopped actor and final EOF translation" do
    state = child("exec cat") |> pending(51)
    port = state.port
    generation = PortRunner.identity(port)
    assert :ok = PortRunner.close(port)
    assert_receive {:arbor_rpc, ^generation, {:closed, :closed, ""}}
    reason = {:cleanup_failed, {:exit_status, 0}, {:error, :cleanup_timeout}}

    message =
      {:arbor_rpc, generation, {:closed, reason, Jason.encode!(%{"type" => "agent_settled"})}}

    assert {:messages, [response], state} = Pi.handle_adapter_message(message, state)
    assert response["id"] == 51
    assert response["result"]["stopReason"] == "end_turn"
    assert state.cleanup_result == {:error, :cleanup_timeout}
    assert {:error, :cleanup_timeout, ^state} = Pi.shutdown(state)

    assert {:error, ":cleanup_timeout", next_state} =
             Pi.translate_outbound(
               %{"method" => "session/new", "id" => 52, "params" => %{"cwd" => File.cwd!()}},
               state
             )

    assert next_state.port == nil
    assert next_state.cleanup_result == {:error, :cleanup_timeout}
  end

  test "managed frames retain credit until the translated output is admitted" do
    state = child("exec cat")
    generation = PortRunner.identity(state.port)

    first = event("one")
    second = event("two")
    assert :ok = PortRunner.command(state.port, [first, "\n", second, "\n"])

    assert_receive {:arbor_rpc, ^generation, {:frame, first_token, ^first}} = message, 500
    assert Pi.subprocess_receipt(message, state) == {state.port, first_token}
    assert {:messages, [first_update], state} = Pi.handle_adapter_message(message, state)
    assert first_update["params"]["update"]["content"]["text"] == "one"
    refute_receive {:arbor_rpc, ^generation, {:frame, _, _}}, 30

    assert :ok = PortRunner.ack(state.port, first_token)
    assert_receive {:arbor_rpc, ^generation, {:frame, second_token, ^second}} = message, 500
    assert {:messages, [second_update], state} = Pi.handle_adapter_message(message, state)
    assert second_update["params"]["update"]["content"]["text"] == "two"
    assert :ok = PortRunner.ack(state.port, second_token)
    assert %Pi{port: nil, cleanup_result: :ok} = Pi.shutdown(state)
  end

  test "a final message without LF completes the prompt before native exit errors" do
    line = Jason.encode!(%{"type" => "agent_settled"})
    state = child("printf '%s' '#{line}'") |> pending(7)
    generation = PortRunner.identity(state.port)

    assert_receive {:arbor_rpc, ^generation, {:closed, {:exit_status, 0}, ^line}} = message, 500
    assert Pi.subprocess_receipt(message, state) == nil
    assert {:messages, [response], state} = Pi.handle_adapter_message(message, state)
    assert response["id"] == 7
    assert response["result"]["stopReason"] == "end_turn"
    refute Map.has_key?(response, "error")
    assert state.port == nil
    assert state.port_monitor == nil
    assert state.pending_prompt == nil
  end

  test "stale generations and unrelated process deaths cannot change the active session" do
    state = child("exec cat")
    stale = {:arbor_rpc, make_ref(), {:frame, make_ref(), event("stale")}}

    assert Pi.subprocess_receipt(stale, state) == nil
    assert {:skip, ^state} = Pi.handle_adapter_message(stale, state)

    assert {:skip, ^state} =
             Pi.handle_adapter_message({:DOWN, make_ref(), :process, self(), :normal}, state)

    assert PortRunner.connected?(state.port)
  end

  test "an abrupt shared actor death fails pending work and clears the session handle" do
    state = child("exec cat") |> pending(8)
    [actor] = Subprocess.linked_processes(state.port)
    Process.exit(actor, :kill)
    monitor = state.port_monitor
    assert_receive {:DOWN, ^monitor, :process, ^actor, :killed} = message, 500

    assert {:messages, [response], state} = Pi.handle_adapter_message(message, state)
    assert response["id"] == 8
    assert response["error"]["message"] =~ "actor_down"
    assert state.port == nil
    assert state.pending_prompt == nil
  end

  test "oversized unfinished native output fails pending work through shared framing" do
    state = child("printf '12345'; sleep 1", max_frame_bytes: 4) |> pending(9)
    generation = PortRunner.identity(state.port)
    assert_receive {:arbor_rpc, ^generation, {:closed, :frame_too_large, _}} = message, 500
    assert {:messages, [response], state} = Pi.handle_adapter_message(message, state)
    assert response["id"] == 9
    assert response["error"]["message"] =~ "frame_too_large"
    assert state.port == nil
    assert state.buffer == ""
  end

  test "banner retention has aggregate count and byte limits" do
    for {opts, banners, reason} <- [
          {[max_prelude_lines: 1], ["first", "second"], {:prelude_overflow, 2, 11}},
          {[max_prelude_bytes: 5], ["☃☃"], {:prelude_overflow, 1, 6}}
        ] do
      state = child("exec cat", opts) |> pending(10)
      generation = PortRunner.identity(state.port)

      state =
        Enum.reduce(banners, state, fn banner, state ->
          port = state.port
          assert :ok = PortRunner.command(port, [banner, "\n"])
          assert_receive {:arbor_rpc, ^generation, {:frame, token, ^banner}} = message, 500

          case Pi.handle_adapter_message(message, state) do
            {:skip, state} ->
              assert :ok = PortRunner.ack(state.port, token)
              state

            {:messages, [response], state} ->
              assert response["error"]["message"] =~ "prelude_overflow"
              assert {:error, :closed} = PortRunner.ack(port, token)
              state
          end
        end)

      assert state.subprocess_error == {:error, reason}
      assert state.port == nil
      assert state.prelude_lines == []
    end
  end

  test "a rejected queued prompt write preserves admitted settlement and fails the new prompt" do
    line = Jason.encode!(%{"type" => "agent_settled"})
    state = child("printf '%s\\n' '#{line}'; exec cat", max_write_bytes: 1) |> pending(11)

    state = %{
      state
      | prompt_queue:
          PromptQueue.from_list([
            %{acp_id: 12, message: "queued", images: [], params: %{}}
          ])
    }

    generation = PortRunner.identity(state.port)

    assert_receive {:arbor_rpc, ^generation, {:frame, _token, ^line}} = message, 500
    assert {:messages, messages, state} = Pi.handle_adapter_message(message, state)
    assert Enum.find(messages, &(&1["id"] == 11))["result"]["stopReason"] == "end_turn"
    assert Enum.find(messages, &(&1["id"] == 12))["error"]["message"] =~ "write_failed"
    assert state.subprocess_error == {:error, {:write_failed, ":write_too_large"}}
    assert state.port == nil
    assert state.pending_prompt == nil
  end

  defp eventually(predicate, attempts \\ 100)

  defp eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end

  defp eventually(_predicate, 0), do: flunk("utility child did not stop")

  defp child(script, opts \\ []) do
    {:ok, port} = PortRunner.open("sh", ["-c", script], opts, Pi)
    on_exit(fn -> PortRunner.close(port) end)
    [actor] = Subprocess.linked_processes(port)
    {:ok, state} = Pi.init(opts)
    %{state | port: port, port_monitor: Process.monitor(actor), session_id: "s1"}
  end

  defp pending(state, id),
    do: %{state | pending_prompt: %{acp_id: id, msg_id: "m", cancel_requested: false}}

  defp event(text),
    do:
      Jason.encode!(%{
        "type" => "message_update",
        "assistantMessageEvent" => %{"type" => "text_delta", "delta" => text}
      })
end
