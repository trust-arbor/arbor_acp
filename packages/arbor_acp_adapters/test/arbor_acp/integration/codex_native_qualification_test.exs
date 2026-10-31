defmodule Arbor.ACP.Integration.CodexNativeQualificationTest do
  use ExUnit.Case, async: false
  alias Arbor.ACP.Adapters.Codex.Native
  alias Arbor.ACP.Test.CodexNative, as: Harness
  @moduletag :external
  @moduletag :codex_authenticated
  @moduletag timeout: 180_000

  test "authenticated native turn streams text and completes" do
    Harness.with_client("authenticated_streaming", [authenticated: true], fn %{
                                                                               client: client,
                                                                               root: root
                                                                             } ->
      consumer = Harness.subscribe!(client)
      thread = Harness.start_thread!(client, root)
      id = thread["thread"]["id"]
      started = Harness.turn!(client, id, "Reply only native-stream-ready. Do not use tools.")
      completed = Harness.await_turn(consumer, id, started["turn"]["id"])
      Harness.assert_completed!(completed)
      assert String.contains?(Harness.text(completed), "native-stream-ready")
      %{model: thread["model"], streamed_text_verified: true}
    end)
  end

  test "managed prompt passes outputSchema and retains ACP streaming" do
    Harness.with_client(
      "authenticated_structured_output",
      [authenticated: true, native_mode: :shared],
      fn %{client: client, root: root} ->
        consumer = Harness.subscribe!(client)

        assert {:ok, %{"sessionId" => id}} =
                 Native.new_session(client, root,
                   native_params:
                     Map.merge(%{"ephemeral" => true}, Harness.qualification_model_params())
                 )

        schema = %{
          "type" => "object",
          "properties" => %{
            "answer" => %{"type" => "string", "enum" => ["native-ready"]},
            "count" => %{"type" => "integer", "enum" => [2]}
          },
          "required" => ["answer", "count"],
          "additionalProperties" => false
        }

        result =
          Native.prompt_text(client, id, "Respond with native-ready. Do not use tools.",
            native_params: %{"outputSchema" => schema},
            timeout: 130_000
          )

        assert match?({:ok, %{truncated?: false}}, result), "Managed structured prompt failed"
        {:ok, reply} = result
        assert %{"answer" => "native-ready", "count" => 2} == Jason.decode!(reply.text)
        completed = Harness.await_turn(consumer, id)
        Harness.assert_completed!(completed)

        assert_receive {:qualification_acp_update, %{"sessionUpdate" => "agent_message_chunk"}},
                       5_000

        %{output_schema_verified: true, acp_streaming_verified: true}
      end
    )
  end

  test "experimental dynamic tool requests return native callback results" do
    Harness.with_client("authenticated_dynamic_tool", [authenticated: true], fn %{
                                                                                  client: client,
                                                                                  root: root,
                                                                                  proof: proof
                                                                                } ->
      consumer = Harness.subscribe!(client)

      tool =
        Harness.dynamic_tool("qualification_echo", %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "string", "enum" => ["native-input"]}},
          "required" => ["value"],
          "additionalProperties" => false
        })

      thread = Harness.start_thread!(client, root, %{"dynamicTools" => [tool]})
      id = thread["thread"]["id"]

      started =
        Harness.turn!(
          client,
          id,
          "Call qualification_echo with value native-input exactly once. Its response contains a fresh proof value different from the input. Copy the response text exactly as your final answer; do not echo the input argument. Do not use other tools."
        )

      completed = Harness.await_turn(consumer, id, started["turn"]["id"])
      Harness.assert_completed!(completed)
      assert_receive {:qualification_tool, call_id}, 5_000
      assert is_binary(call_id)

      tool_item =
        Enum.find_value(completed.events, fn
          %{
            "method" => "item/completed",
            "params" => %{"item" => %{"type" => "dynamicToolCall", "id" => ^call_id} = item}
          } ->
            item

          _other ->
            nil
        end)

      assert %{
               "status" => "completed",
               "success" => true,
               "contentItems" => [%{"type" => "inputText", "text" => ^proof}]
             } = tool_item

      assert Enum.any?(completed.events, fn event ->
               event["method"] == "item/tool/call" and
                 get_in(event, ["params", "callId"]) == call_id
             end),
             "Native dynamic-tool request was not observed"

      %{
        model: thread["model"],
        dynamic_tool_roundtrip_verified: true,
        model_echoed_tool_result: String.contains?(Harness.text(completed), proof)
      }
    end)
  end

  test "native command approval reaches the callback and denial prevents the write" do
    Harness.with_client("authenticated_approval_denial", [authenticated: true], fn %{
                                                                                     client:
                                                                                       client,
                                                                                     root: root
                                                                                   } ->
      consumer = Harness.subscribe!(client)
      thread = Harness.start_thread!(client, root, %{"approvalPolicy" => "untrusted"})
      id = thread["thread"]["id"]
      marker = Path.join(root, "approval-marker")

      started =
        Harness.turn!(
          client,
          id,
          "Use the shell tool to run exactly: printf native-approval > '#{marker}'. Request approval to write despite the read-only sandbox. If declined, stop without retrying or using another tool."
        )

      completed = Harness.await_turn(consumer, id, started["turn"]["id"])
      Harness.assert_completed!(completed)

      assert_receive {:qualification_approval, "item/commandExecution/requestApproval", item},
                     5_000

      assert is_binary(item)
      refute File.exists?(marker)
      Harness.await_method(consumer, "serverRequest/resolved")
      %{model: thread["model"], approval_denial_verified: true}
    end)
  end

  test "interrupting a real turn resolves a pending native callback and suppresses its late reply" do
    Harness.with_client("authenticated_interruption", [authenticated: true], fn %{
                                                                                  client: client,
                                                                                  root: root
                                                                                } ->
      consumer = Harness.subscribe!(client)

      tool =
        Harness.dynamic_tool("qualification_hold", %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => false
        })

      thread = Harness.start_thread!(client, root, %{"dynamicTools" => [tool]})
      id = thread["thread"]["id"]

      started =
        Harness.turn!(
          client,
          id,
          "Call qualification_hold exactly once before answering. Do not use other tools."
        )

      turn = started["turn"]["id"]
      assert_receive {:qualification_held, handler}, 90_000

      try do
        assert is_map(
                 Harness.request!(client, "turn/interrupt", %{"threadId" => id, "turnId" => turn})
               )

        completed = Harness.await_turn(consumer, id, turn, 30_000)
        assert completed.turn["status"] == "interrupted"
        bridge = :sys.get_state(client).transport_state.bridge
        pending_count = map_size(:sys.get_state(bridge).adapter_state.pending_client_requests)
        resolution_seen = Enum.any?(completed.events, &(&1["method"] == "serverRequest/resolved"))

        assert pending_count == 0,
               "Interrupted turn retained #{pending_count} callback(s); native resolution observed: #{resolution_seen}"

        assert :sys.get_state(client).pending_agent_requests == %{},
               "Interrupted turn retained a core callback"
      after
        send(handler, :release_qualification)
      end

      # Wait for the callback to return and enqueue its late result before probing.
      :sys.get_state(handler)
      assert is_list(Harness.request!(client, "thread/loaded/list")["data"])
      bridge = :sys.get_state(client).transport_state.bridge
      assert :sys.get_state(bridge).adapter_state.pending_client_requests == %{}
      %{model: thread["model"], interruption_verified: true, late_reply_suppressed: true}
    end)
  end
end
