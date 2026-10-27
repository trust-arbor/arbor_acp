defmodule Arbor.ACP.AdapterBridgeContractTest do
  # Every result shape the Arbor.ACP.Adapter callbacks may return, through
  # every bridge route that calls them, with the accompanying write accepted
  # or rejected. The bridge must neither crash nor answer a request twice; a
  # result or error the adapter gives is answered exactly once; responses the
  # adapter emits for other requests always reach the client, while
  # notifications go only when their write was accepted.
  use ExUnit.Case, async: true

  alias Arbor.ACP.AdapterBridge

  @write "native-write\n"

  defmodule ShapeAdapter do
    @moduledoc false
    @behaviour Arbor.ACP.Adapter

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    # `cat` echoes every write back as one native line.
    @impl true
    def command(_opts), do: {"cat", []}

    @impl true
    def capabilities do
      %{
        "loadSession" => true,
        "sessionCapabilities" => %{
          "list" => %{},
          "resume" => %{},
          "close" => %{},
          "delete" => %{}
        }
      }
    end

    @impl true
    def auth_methods(_opts), do: [%{"id" => "contract", "name" => "Contract"}]

    @impl true
    def translate_outbound(%{"method" => "initialize"}, state), do: {:ok, :skip, state}

    def translate_outbound(%{"params" => %{"shape" => shape}} = message, state),
      do: Arbor.ACP.AdapterBridgeContractTest.outbound(shape, message, state)

    # A client's response to an agent request.
    def translate_outbound(%{"result" => %{"shape" => shape}} = message, state),
      do: Arbor.ACP.AdapterBridgeContractTest.outbound(shape, message, state)

    def translate_outbound(_message, state), do: {:ok, :skip, state}

    @impl true
    def translate_inbound(line, state),
      do: Arbor.ACP.AdapterBridgeContractTest.inbound(String.trim(line), state)

    @impl true
    def handle_adapter_message({:contract, shape}, state),
      do: Arbor.ACP.AdapterBridgeContractTest.adapter_message(shape, state)

    def handle_adapter_message(_message, state), do: {:skip, state}

    @impl true
    def outbound_write_failed(message, reason, state) do
      send(state.test_pid, {:write_failed, message["id"], reason})
      state
    end
  end

  @outbound_shapes ~w(ok_skip ok_pending ok_write reply messages messages_and_reply
                      messages_and_write reply_and_write pending_and_write
                      messages_and_reply_and_write error bare_error one_shot)

  @results ~w(reply messages_and_reply reply_and_write messages_and_reply_and_write)
  @writes ~w(ok_write messages_and_write reply_and_write pending_and_write
             messages_and_reply_and_write)
  @with_messages ~w(messages messages_and_reply messages_and_write messages_and_reply_and_write)

  @requests ~w(session/new session/load session/resume session/list session/prompt
               session/close session/delete session/set_mode session/set_model
               session/set_config_option authenticate)

  @doc false
  def outbound(shape, %{} = message, state) do
    id = message["id"]
    messages = [other_response(id), notification(id)]
    result = %{"shape" => shape}

    case shape do
      "ok_skip" ->
        {:ok, :skip, state}

      "ok_pending" ->
        {:ok, :pending, state}

      "ok_write" ->
        {:ok, @write, state}

      "reply" ->
        {:reply, result, state}

      "messages" ->
        {:messages, messages, state}

      "messages_and_reply" ->
        {:messages_and_reply, messages, result, state}

      "messages_and_write" ->
        {:messages_and_write, messages, @write, state}

      "reply_and_write" ->
        {:reply_and_write, result, @write, state}

      "pending_and_write" ->
        {:pending_and_write, @write, state}

      "messages_and_reply_and_write" ->
        {:messages_and_reply_and_write, messages, result, @write, state}

      "error" ->
        {:error, "contract error", state}

      "bare_error" ->
        {:error, "contract bare error"}

      "one_shot" ->
        {:one_shot, fn -> {:ok, [Jason.encode!(one_shot_message(id))]} end, state}
    end
  end

  @doc false
  def inbound("inbound " <> shape, state) do
    case shape do
      "messages" -> {:messages, [notification("inbound")], state}
      "messages_and_write" -> {:messages_and_write, [notification("inbound")], "echoed\n", state}
      "skip_and_write" -> {:skip_and_write, "echoed\n", state}
      "partial" -> {:partial, state}
      "skip" -> {:skip, state}
    end
  end

  def inbound(_line, state), do: {:skip, state}

  @doc false
  def adapter_message(shape, state) do
    case shape do
      "messages" -> {:messages, [notification("adapter")], state}
      "partial" -> {:partial, state}
      "skip" -> {:skip, state}
    end
  end

  defp other_response(id),
    do: %{"jsonrpc" => "2.0", "id" => "other-#{id}", "result" => %{"settled" => true}}

  defp notification(id),
    do: %{"jsonrpc" => "2.0", "method" => "contract/notice", "params" => %{"for" => id}}

  defp one_shot_message(id),
    do: %{"jsonrpc" => "2.0", "id" => id, "result" => %{"oneShot" => true}}

  for writes? <- [true, false], method <- @requests, shape <- @outbound_shapes do
    @tag writes: writes?, method: method, shape: shape
    test "#{method} returning #{shape} with the write #{if writes?, do: "accepted", else: "rejected"}",
         context do
      check_request(context.method, context.shape, context.writes)
    end
  end

  for writes? <- [true, false], shape <- @outbound_shapes do
    @tag writes: writes?, shape: shape
    test "session/cancel notification returning #{shape} with the write #{if writes?, do: "accepted", else: "rejected"}",
         context do
      bridge = start_bridge(context.writes)

      message = %{
        "jsonrpc" => "2.0",
        "method" => "session/cancel",
        "params" => %{"shape" => context.shape}
      }

      result = AdapterBridge.send_message(bridge, Jason.encode!(message))

      assert result == :ok or match?({:error, _reason}, result)
      assert Process.alive?(bridge)
      output = collect(bridge, context.shape)

      if context.shape in @with_messages do
        assert Enum.any?(output, &(&1["id"] == "other-"))
      end

      close(bridge)
    end
  end

  # The response carries the agent's id, which the client may also use for
  # one of its own requests; answering it would answer that request.
  for shape <- ~w(ok_write messages_and_write) do
    @tag shape: shape
    test "a client response whose #{shape} write is rejected is not answered", context do
      bridge = start_bridge(false)
      response = %{"jsonrpc" => "2.0", "id" => 7, "result" => %{"shape" => context.shape}}

      assert {:error, :write_too_large} =
               AdapterBridge.send_message(bridge, Jason.encode!(response))

      assert Process.alive?(bridge)
      assert collect(bridge, nil) |> Enum.filter(&response_to?(&1, 7)) == []
      assert_received {:write_failed, 7, :write_too_large}
      close(bridge)
    end
  end

  for shape <- ~w(messages messages_and_write skip_and_write partial skip) do
    @tag shape: shape
    test "translate_inbound returning #{shape}", context do
      bridge = start_bridge(true)
      # `cat` echoes this back as the native line the adapter translates.
      port = :sys.get_state(bridge).port
      :ok = Arbor.ACP.AdapterSupport.Subprocess.command(port, "inbound #{context.shape}\n")

      if context.shape in ["messages", "messages_and_write"] do
        assert {:ok, raw} = AdapterBridge.receive_message(bridge, 2_000)
        assert Jason.decode!(raw)["params"]["for"] == "inbound"
      end

      assert Process.alive?(bridge)
      assert :sys.get_state(bridge).status == :ready
      close(bridge)
    end
  end

  for shape <- ~w(messages partial skip) do
    @tag shape: shape
    test "handle_adapter_message returning #{shape}", context do
      bridge = start_bridge(true)
      send(bridge, {:contract, context.shape})

      if context.shape == "messages" do
        assert {:ok, raw} = AdapterBridge.receive_message(bridge, 2_000)
        assert Jason.decode!(raw)["params"]["for"] == "adapter"
      end

      assert Process.alive?(bridge)
      assert :sys.get_state(bridge).status == :ready
      close(bridge)
    end
  end

  defp check_request(method, shape, writes?) do
    bridge = start_bridge(writes?)
    id = 7
    params = %{"shape" => shape, "sessionId" => "s", "cwd" => "/tmp", "modelId" => "m"}
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(message))
    assert Process.alive?(bridge)

    output = collect(bridge, shape)
    answers = Enum.filter(output, &response_to?(&1, id))
    assert length(answers) <= 1, "#{method} #{shape} answered twice: #{inspect(answers)}"

    write_failed? = shape in @writes and not writes?

    cond do
      shape in ["error", "bare_error"] or write_failed? ->
        assert [%{"error" => %{}}] = answers

      shape in @results ->
        assert [%{"result" => result}] = answers
        assert result["shape"] == shape

      shape == "one_shot" ->
        assert [%{"result" => %{"oneShot" => true}}] = answers

      # An adapter that already wrote answers the request itself.
      shape == "ok_pending" ->
        assert answers == []

      true ->
        :ok
    end

    # The adapter hears of every failed write, so it can retire the request.
    if write_failed? do
      assert_received {:write_failed, ^id, :write_too_large}
    else
      refute_received {:write_failed, _id, _reason}
    end

    if shape in @with_messages do
      assert Enum.any?(output, &(&1["id"] == "other-#{id}")),
             "#{method} #{shape} lost the response it settled"

      notice? = Enum.any?(output, &(&1["method"] == "contract/notice"))
      assert notice? == not write_failed?
    end

    close(bridge)
  end

  defp start_bridge(writes?) do
    opts = if writes?, do: [test_pid: self()], else: [test_pid: self(), max_write_bytes: 4]
    {:ok, bridge} = AdapterBridge.start_link(adapter: ShapeAdapter, adapter_opts: opts)
    bridge
  end

  defp close(bridge), do: assert(:ok = AdapterBridge.close(bridge))

  # A one-shot task answers from its own process, so wait for it.
  defp collect(bridge, "one_shot") do
    case AdapterBridge.receive_message(bridge, 2_000) do
      {:ok, raw} -> [Jason.decode!(raw) | collect(bridge, nil)]
      {:error, _reason} -> []
    end
  end

  defp collect(bridge, _shape) do
    case AdapterBridge.receive_message(bridge, 0) do
      {:ok, raw} -> [Jason.decode!(raw) | collect(bridge, nil)]
      {:error, _reason} -> []
    end
  end

  defp response_to?(message, id),
    do: message["id"] == id and not Map.has_key?(message, "method")
end
