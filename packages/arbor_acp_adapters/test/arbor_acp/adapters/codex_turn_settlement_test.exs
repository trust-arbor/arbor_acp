defmodule Arbor.ACP.Adapters.CodexTurnSettlementTest do
  use ExUnit.Case, async: true
  alias Arbor.ACP.Adapters.Codex

  setup do
    {:ok, state} = Codex.init(cwd: File.cwd!(), trust_workspace_config: true)

    {:ok, data, state} =
      Codex.translate_outbound(request(1, "session/new", %{"cwd" => File.cwd!()}), state)

    native_id = decode(data)["id"]

    {:messages, _messages, state} =
      inbound(state, %{"id" => native_id, "result" => %{"thread" => %{"id" => "thread-1"}}})

    %{state: state}
  end

  test "a rejected turn's completion cannot settle the next prompt before its start reply", %{
    state: state
  } do
    failed = prompt(100)
    {:ok, _data, state} = Codex.translate_outbound(failed, state)
    state = Codex.outbound_write_failed(failed, :write_too_large, state)
    {:ok, data, state} = Codex.translate_outbound(prompt(101), state)
    native_id = decode(data)["id"]
    assert {:skip, state} = inbound(state, completed("old-turn"))
    assert state.sessions["thread-1"].active_prompt_acp_id == 101

    {:skip, state} =
      inbound(state, %{"id" => native_id, "result" => %{"turn" => %{"id" => "new-turn"}}})

    {:messages, messages, state} = inbound(state, completed("new-turn"))
    assert [%{"id" => 101, "result" => _}] = answers(messages)
    assert state.sessions["thread-1"].active_prompt_acp_id == nil
  end

  test "a different turn cannot settle a prompt whose turn id is known", %{state: state} do
    {:ok, data, state} = Codex.translate_outbound(prompt(100), state)

    {:skip, state} =
      inbound(state, %{"id" => decode(data)["id"], "result" => %{"turn" => %{"id" => "current"}}})

    assert {:skip, state} = inbound(state, completed("old"))
    assert state.sessions["thread-1"].turn_id == "current"
    {:messages, messages, _state} = inbound(state, completed("current"))
    assert [%{"id" => 100, "result" => _}] = answers(messages)
  end

  test "a completion before its start reply retires the reply's pending correlation", %{
    state: state
  } do
    {:ok, data, state} = Codex.translate_outbound(prompt(100), state)
    native_id = decode(data)["id"]

    {:skip, state} =
      inbound(state, %{
        "method" => "turn/started",
        "params" => %{"threadId" => "thread-1", "turn" => %{"id" => "current"}}
      })

    {:messages, messages, state} = inbound(state, completed("current"))
    assert [%{"id" => 100, "result" => _}] = answers(messages)
    refute Map.has_key?(state.pending_requests, native_id)

    assert {:skip, state} =
             inbound(state, %{"id" => native_id, "result" => %{"turn" => %{"id" => "current"}}})

    {:messages, messages, state} = inbound(state, completed("current"))
    assert answers(messages) == []
    assert state.sessions["thread-1"].active_prompt_acp_id == nil
  end

  test "legacy completions without a turn id still settle an acknowledged prompt", %{state: state} do
    {:ok, data, state} = Codex.translate_outbound(prompt(100), state)

    {:skip, state} =
      inbound(state, %{"id" => decode(data)["id"], "result" => %{"turn" => %{"id" => "current"}}})

    {:messages, messages, _state} =
      inbound(state, %{
        "method" => "turn/completed",
        "params" => %{"threadId" => "thread-1", "status" => "completed"}
      })

    assert [%{"id" => 100, "result" => _}] = answers(messages)
  end

  defp prompt(id),
    do:
      request(id, "session/prompt", %{
        "sessionId" => "thread-1",
        "prompt" => [%{"type" => "text", "text" => "hello"}]
      })

  defp request(id, method, params),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp completed(id),
    do: %{
      "method" => "turn/completed",
      "params" => %{"threadId" => "thread-1", "turn" => %{"id" => id, "status" => "completed"}}
    }

  defp inbound(state, msg), do: Codex.translate_inbound(Jason.encode!(msg), state)
  defp decode(data), do: data |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()
  defp answers(messages), do: Enum.filter(messages, &Map.has_key?(&1, "id"))
end
