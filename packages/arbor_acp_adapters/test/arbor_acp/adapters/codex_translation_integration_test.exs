defmodule ArborACP.Adapters.CodexTranslationIntegrationTest do
  use ExUnit.Case, async: true

  describe "Codex adapter translate chain" do
    @moduletag :codex_translate

    alias ArborACP.Adapters.Codex

    test "full outbound→inbound flow for thread lifecycle" do
      cwd = File.cwd!()
      {:ok, state} = Codex.init(model: "gpt-4o", cwd: cwd)

      # post_connect sends initialize
      {:ok, init_data, state} = Codex.post_connect(state)
      init_json = IO.iodata_to_binary(init_data)
      {:ok, init_msg} = Jason.decode(init_json)
      assert init_msg["method"] == "initialize"

      # Simulate Codex response
      init_response = Jason.encode!(%{"id" => 1, "result" => %{"capabilities" => %{}}})
      {:skip_and_write, initialized_data, state} = Codex.translate_inbound(init_response, state)
      assert state.phase == :ready

      [initialized_msg, model_list_msg] =
        initialized_data
        |> IO.iodata_to_binary()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert initialized_msg["method"] == "initialized"
      assert model_list_msg["method"] == "model/list"

      # session/new → thread/start
      {:ok, thread_data, state} =
        Codex.translate_outbound(
          %{
            "method" => "session/new",
            "id" => 10,
            "params" => %{"cwd" => cwd, "mcpServers" => []}
          },
          state
        )

      thread_json = IO.iodata_to_binary(thread_data)
      {:ok, thread_msg} = Jason.decode(thread_json)
      assert thread_msg["method"] == "thread/start"
      assert thread_msg["params"]["model"] == "gpt-4o"

      # Simulate Codex thread/start response
      thread_response =
        Jason.encode!(%{
          "id" => thread_msg["id"],
          "result" => %{"thread" => %{"id" => "thread-42"}}
        })

      {:messages, [new_resp], state} = Codex.translate_inbound(thread_response, state)
      assert new_resp["id"] == 10
      assert new_resp["result"]["sessionId"] == "thread-42"
      assert state.sessions["thread-42"].id == "thread-42"

      # session/prompt → turn/start
      {:ok, turn_data, state} =
        Codex.translate_outbound(
          %{
            "method" => "session/prompt",
            "id" => 11,
            "params" => %{
              "sessionId" => "thread-42",
              "prompt" => [%{"type" => "text", "text" => "Fix the tests"}]
            }
          },
          state
        )

      turn_json = IO.iodata_to_binary(turn_data)
      {:ok, turn_msg} = Jason.decode(turn_json)
      assert turn_msg["method"] == "turn/start"
      assert turn_msg["params"]["threadId"] == "thread-42"

      assert turn_msg["params"]["input"] == [
               %{"type" => "text", "text" => "Fix the tests", "text_elements" => []}
             ]

      # Simulate turn/start response
      turn_response =
        Jason.encode!(%{
          "id" => turn_msg["id"],
          "result" => %{"turn" => %{"id" => "turn-99"}}
        })

      {:skip, state} = Codex.translate_inbound(turn_response, state)
      assert state.sessions["thread-42"].turn_id == "turn-99"

      # Simulate streaming text delta
      delta1 =
        Jason.encode!(%{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => "I'll fix ", "threadId" => "thread-42", "turnId" => "turn-99"}
        })

      {:messages, [upd1], state} = Codex.translate_inbound(delta1, state)
      assert upd1["params"]["update"]["sessionUpdate"] == "agent_message_chunk"
      assert upd1["params"]["update"]["content"] == %{"type" => "text", "text" => "I'll fix "}

      delta2 =
        Jason.encode!(%{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => "the tests.", "threadId" => "thread-42", "turnId" => "turn-99"}
        })

      {:messages, [upd2], state} = Codex.translate_inbound(delta2, state)
      assert upd2["params"]["update"]["content"] == %{"type" => "text", "text" => "the tests."}

      # Simulate turn/completed
      completed =
        Jason.encode!(%{
          "method" => "turn/completed",
          "params" => %{
            "turn" => %{"id" => "turn-99", "status" => "completed"},
            "threadId" => "thread-42"
          }
        })

      {:messages, messages, _state} = Codex.translate_inbound(completed, state)
      final = Enum.find(messages, &Map.has_key?(&1, "id"))
      assert final["id"] == 11
      assert final["result"]["_meta"]["ex_mcp"]["text"] == "I'll fix the tests."
      assert final["result"]["stopReason"] == "end_turn"
      assert final["result"]["_meta"]["ex_mcp"]["sessionId"] == "thread-42"
    end
  end
end
