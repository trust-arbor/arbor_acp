defmodule Arbor.ACP.Adapters.BridgeFailedWriteTest do
  # The adapter side of Arbor.ACP.AdapterBridgeContractTest (core), which
  # cannot load the adapters this package ships. For each adapter and each
  # route it tracks before writing, a request is sent through the real bridge
  # with a write too large for the bridge's `max_write_bytes`, so the write is
  # rejected while the native process stays up. Then:
  #
  #   * the request is answered once, with the write's error, and the adapter
  #     tracks nothing more than before it;
  #   * the native reply that request would have had answers nothing;
  #   * a request of the same kind that does fit is written and answered.
  #
  # The fake native process prints only what the test sends it, so every
  # native reply is the test's; the next request's answer is the barrier,
  # since the bridge handles native lines in order.
  # Native startup is part of a bounded fixture setup, so run this module
  # after async modules instead of competing with their subprocess launches.
  use ExUnit.Case, async: false

  alias Arbor.ACP.AdapterBridge
  alias Arbor.ACP.Adapters.{ClaudeSDK, Codex, ZCode}
  alias Arbor.ACP.Adapters.Internal.PromptQueue
  alias Arbor.ACP.Adapters.Pi.RPC
  alias Arbor.ACP.AdapterSupport.Subprocess, as: PortRunner
  alias Arbor.ACP.Test.PiBridgeModel.UnmanagedPi

  @limit 1_024
  @huge String.duplicate("x", 4_096)
  @failed 100
  @next 101

  @cases [
    {:claude, "session/prompt"},
    {:claude, "session/set_config_option"},
    {:codex, "session/new"},
    {:codex, "session/load"},
    {:codex, "session/resume"},
    {:codex, "session/list"},
    {:codex, "session/prompt"},
    {:codex, "authenticate"},
    {:zcode, "session/new"},
    {:zcode, "session/load"},
    {:zcode, "session/resume"},
    {:zcode, "session/list"},
    {:zcode, "session/prompt"},
    {:zcode, "session/fork"},
    {:zcode, "session/close"},
    {:pi, "session/prompt"},
    {:pi, "slash command"},
    {:pi, "session/resume"}
  ]

  setup do
    dir = Path.join(System.tmp_dir!(), "failed_write_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    native = Path.join(dir, "native")

    # Prints what the test sends it with `__emit__`, and answers on its own
    # once it reads a line holding a pattern registered with `__when__`, so a
    # turn can finish only when the agent really received what it waits for.
    # Everything the adapter writes is logged to `received`.
    File.write!(native, """
    #!/bin/sh
    dir=$(dirname "$0")
    tab=$(printf '\\t')
    : > "$dir/triggers"
    hold=0
    while IFS= read -r line; do
      case "$line" in
        "__emit__ "*) printf '%s\\n' "${line#__emit__ }" ;;
        # Stay up after stdin closes, so writes fail while the agent lives.
        "__hold__") hold=1 ;;
        "__when__ "*) printf '%s\\n' "${line#__when__ }" >> "$dir/triggers" ;;
        # Requests too large to send through the limited stdin.
        "__big_select__")
          option=$(head -c 4096 /dev/zero | tr '\\0' x)
          printf '{"type":"extension_ui_request","id":"ui-1","method":"select","title":"Pick","options":["%s"]}\\n' "$option" ;;
        "__big_permission__")
          note=$(head -c 4096 /dev/zero | tr '\\0' x)
          printf '{"id":"perm-1","method":"interaction/requestPermission","params":{"sessionId":"zcode-1","options":[{"optionId":"allow","name":"Allow","kind":"allow_once","response":{"decision":"allow","note":"%s"}}]}}\\n' "$note" ;;
        *)
          printf '%s\\n' "$line" >> "$dir/received"
          while IFS="$tab" read -r pattern reply; do
            case "$line" in *"$pattern"*) printf '%s\\n' "$reply" ;; esac
          done < "$dir/triggers" ;;
      esac
    done
    if [ "$hold" = 1 ]; then while :; do sleep 1; done; fi
    """)

    File.chmod!(native, 0o755)
    %{dir: dir, native: native}
  end

  for {adapter, route} <- @cases do
    @adapter adapter
    @route route
    test "#{adapter} #{route}: a rejected write leaves nothing pending", ctx do
      ctx |> Map.put(:adapter, @adapter) |> scenario(@route) |> run_case()
    end
  end

  # The agent waits, with no timeout, for the client's answer to its own
  # request. When that answer cannot be written, a small error must reach the
  # agent in its place, so its turn ends on its own and the next prompt runs.
  # Each turn here finishes only through the fake's triggers, which fire on
  # what the adapter actually wrote. The Claude and Pi requests share their
  # id with the running prompt, since each side numbers its requests itself.
  describe "a client response too large to write" do
    test "claude: a file-read answer is replaced by an error and the turn ends", ctx do
      ctx = ctx |> Map.put(:adapter, :claude) |> scenario("session/prompt") |> start()
      open_session(ctx, "session/new", %{"cwd" => ctx.dir, "sessionId" => "claude-session"}, [])

      emit(ctx, %{
        "type" => "control_request",
        "request_id" => "read-1",
        "request" => %{"subtype" => "read_file", "path" => Path.join(ctx.dir, "notes.txt")}
      })

      assert %{"method" => "fs/read_text_file", "id" => shared} =
               ctx |> collect_until(&(&1["method"] == "fs/read_text_file")) |> List.last()

      on_receipt(ctx, "could not be forwarded", [claude_result("done")])
      send_request(ctx, shared, "session/prompt", prompt_params("claude-session", "hello"))

      answer_too_large(ctx, %{"id" => shared, "result" => %{"content" => @huge}})
      # The turn ends only after the agent read, and logged, the replacement.
      assert_turn_ended(ctx, shared)
      assert_received_native(ctx, ~s("request_id":"read-1"))

      on_receipt(ctx, "second prompt", [claude_result("second")])
      send_request(ctx, @next, "session/prompt", prompt_params("claude-session", "second prompt"))
      assert_turn_ended(ctx, @next)
    end

    for mode <- [:unmanaged, :managed] do
      @mode mode
      test "pi #{mode}: a dialog answer is replaced by a cancel and the turn ends", ctx do
        ctx = ctx |> Map.put(:adapter, :pi) |> scenario("session/prompt")
        ctx = if @mode == :managed, do: managed_pi(ctx), else: ctx
        ctx = ctx |> start() |> then(& &1.setup.(&1))

        # Pi names its next dialog after the prompt counter.
        shared = "pi-extension-#{adapter_state(ctx).msg_counter + 2}"
        on_receipt(ctx, ~s("message":"hello"), [pi_response("msg-1", "prompt", %{})])
        on_receipt(ctx, ~s("cancelled":true), [pi_agent_end(), %{"type" => "agent_settled"}])
        send_request(ctx, shared, "session/prompt", prompt_params("N1", "hello"))

        assert :ok = PortRunner.command(native_port(ctx), "__big_select__\n")

        assert %{"method" => "session/request_permission", "id" => ^shared} =
                 ctx
                 |> collect_until(&(&1["method"] == "session/request_permission"))
                 |> List.last()

        answer_too_large(ctx, %{
          "id" => shared,
          "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "choice-0"}}
        })

        # The turn ends only after the agent read, and logged, the replacement.
        assert_turn_ended(ctx, shared)
        assert_received_native(ctx, ~s("id":"ui-1"))

        on_receipt(ctx, "second prompt", [
          pi_response("msg-2", "prompt", %{}),
          pi_agent_end(),
          %{"type" => "agent_settled"}
        ])

        send_request(ctx, @next, "session/prompt", prompt_params("N1", "second prompt"))
        assert_turn_ended(ctx, @next)
      end
    end

    test "codex: a user-input answer is replaced by an error and the turn ends", ctx do
      ctx = ctx |> Map.put(:adapter, :codex) |> scenario("session/prompt") |> start()
      capabilities = %{"clientCapabilities" => %{"elicitation" => %{"form" => %{}}}}
      send_request(ctx, 0, "initialize", Map.put(capabilities, "protocolVersion", 1))
      _ = collect_until(ctx, &response_to?(&1, 0))
      ctx = ctx.setup.(ctx)

      turn_start = adapter_state(ctx).next_id

      on_receipt(ctx, "hello", [
        %{"id" => turn_start, "result" => %{"turn" => %{"id" => "turn-1"}}}
      ])

      on_receipt(ctx, "could not be forwarded", [codex_turn_completed("turn-1")])
      send_request(ctx, 10, "session/prompt", prompt_params("thread-1", "hello"))

      emit(ctx, %{
        "id" => 900,
        "method" => "item/tool/requestUserInput",
        "params" => %{
          "threadId" => "thread-1",
          "itemId" => "item-1",
          "questions" => [%{"id" => "q1", "question" => "Name?"}]
        }
      })

      assert %{"method" => "elicitation/create", "id" => asked} =
               ctx |> collect_until(&(&1["method"] == "elicitation/create")) |> List.last()

      answer_too_large(ctx, %{
        "id" => asked,
        "result" => %{"action" => "accept", "content" => %{"q1" => @huge}}
      })

      # The turn ends only after the agent read, and logged, the replacement.
      assert_turn_ended(ctx, 10)
      assert_received_native(ctx, ~s("id":900))

      turn_start = adapter_state(ctx).next_id

      on_receipt(ctx, "second prompt", [
        %{"id" => turn_start, "result" => %{"turn" => %{"id" => "turn-2"}}},
        codex_turn_completed("turn-2")
      ])

      send_request(ctx, @next, "session/prompt", prompt_params("thread-1", "second prompt"))
      assert_turn_ended(ctx, @next)
    end

    test "zcode: a permission answer is replaced by a denial and the turn ends", ctx do
      ctx = ctx |> Map.put(:adapter, :zcode) |> scenario("session/prompt") |> start()
      ctx = ctx.setup.(ctx)

      send_id = adapter_state(ctx).next_id
      on_receipt(ctx, "hello", [%{"id" => send_id, "result" => %{}}])
      on_receipt(ctx, "could not be forwarded", [zcode_turn_completed()])
      send_request(ctx, 10, "session/prompt", prompt_params("zcode-1", "hello"))

      assert :ok = PortRunner.command(native_port(ctx), "__big_permission__\n")

      assert %{"method" => "session/request_permission", "id" => asked} =
               ctx
               |> collect_until(&(&1["method"] == "session/request_permission"))
               |> List.last()

      answer_too_large(ctx, %{
        "id" => asked,
        "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow"}}
      })

      # The turn ends only after the agent read, and logged, the replacement.
      assert_turn_ended(ctx, 10)
      assert_received_native(ctx, ~s("id":"perm-1"))

      send_id = adapter_state(ctx).next_id

      on_receipt(ctx, "second prompt", [
        %{"id" => send_id, "result" => %{}},
        zcode_turn_completed()
      ])

      send_request(ctx, @next, "session/prompt", prompt_params("zcode-1", "second prompt"))
      assert_turn_ended(ctx, @next)
    end
  end

  # A managed Pi whose stdin is gone, while the process is still up.
  describe "managed Pi with its input broken" do
    setup ctx do
      ctx = ctx |> Map.put(:adapter, :pi) |> scenario("session/prompt") |> managed_pi() |> start()
      ctx = ctx.setup.(ctx)
      send_request(ctx, 10, "session/prompt", prompt_params("N1", "hello"))
      emit(ctx, pi_response("msg-1", "prompt", %{}))
      Map.put(ctx, :port, native_port(ctx))
    end

    test "a dialog answer that cannot be written reports the error and ends Pi", ctx do
      emit(ctx, %{
        "type" => "extension_ui_request",
        "id" => "ui-1",
        "method" => "select",
        "title" => "Pick",
        "options" => ["a"]
      })

      assert %{"method" => "session/request_permission", "id" => asked} =
               ctx
               |> collect_until(&(&1["method"] == "session/request_permission"))
               |> List.last()

      break_input(ctx.port)

      answer = %{
        "jsonrpc" => "2.0",
        "id" => asked,
        "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "choice-0"}}
      }

      # Neither the answer nor the cancel in its place reaches Pi.
      assert {:error, _reason} = AdapterBridge.send_message(ctx.bridge, Jason.encode!(answer))

      # Pi is closed, and its exit answers the running prompt.
      assert [%{"error" => %{"message" => "Pi process exited" <> _}}] =
               ctx |> collect_until(&response_to?(&1, 10)) |> answers(10)

      assert Process.alive?(ctx.bridge)
      assert adapter_state(ctx).port == nil
      AdapterBridge.close(ctx.bridge)
    end

    test "an auto-cancel that cannot be written ends Pi instead of crashing the bridge", ctx do
      # Pi's notification is already queued for the bridge when its input breaks.
      :sys.suspend(ctx.bridge)

      notify = %{
        "type" => "extension_ui_request",
        "id" => "ui-2",
        "method" => "notify",
        "message" => "heads up"
      }

      assert :ok = PortRunner.command(ctx.port, ["__emit__ ", Jason.encode!(notify), "\n"])

      Arbor.ACP.TestHelpers.wait_until(
        fn ->
          match?({:message_queue_len, n} when n > 0, Process.info(ctx.bridge, :message_queue_len))
        end,
        interval: 1
      )

      break_input(ctx.port)
      :sys.resume(ctx.bridge)

      assert [%{"error" => %{"message" => "Pi process exited" <> _}}] =
               ctx |> collect_until(&response_to?(&1, 10)) |> answers(10)

      assert Process.alive?(ctx.bridge)
      assert adapter_state(ctx).port == nil
      AdapterBridge.close(ctx.bridge)
    end
  end

  defp break_input(port) do
    assert :ok = PortRunner.command(port, "__hold__\n")
    assert :ok = Arbor.RPC.Subprocess.close_input(port)
  end

  defp managed_pi(ctx) do
    opts = ctx.opts |> Keyword.put(:managed, true)
    %{ctx | adapter_mod: Arbor.ACP.Adapters.Pi, opts: opts}
  end

  defp on_receipt(ctx, pattern, replies) do
    for reply <- replies do
      line = ["__when__ ", pattern, "\t", Jason.encode!(reply), "\n"]
      assert :ok = PortRunner.command(native_port(ctx), line)
    end
  end

  # The client's answer is refused, and only the client hears of it.
  defp answer_too_large(ctx, response) do
    message = Map.put(response, "jsonrpc", "2.0")
    assert {:error, _reason} = AdapterBridge.send_message(ctx.bridge, Jason.encode!(message))
  end

  defp assert_received_native(ctx, fragment) do
    received = File.read!(Path.join(ctx.dir, "received"))

    assert Enum.any?(
             String.split(received, "\n"),
             &((String.contains?(&1, fragment) and String.contains?(&1, "could not be forwarded")) or
                 (String.contains?(&1, fragment) and String.contains?(&1, ~s("cancelled":true))))
           ),
           "the agent never received a replacement answer: #{received}"
  end

  defp assert_turn_ended(ctx, id) do
    messages = collect_until(ctx, &response_to?(&1, id))
    assert [%{"result" => %{"stopReason" => _reason}}] = answers(messages, id)
  end

  defp pi_agent_end, do: %{"type" => "agent_end", "messages" => []}

  # -- the check --------------------------------------------------------------

  defp run_case(sc) do
    ctx = sc.setup.(start(sc))
    before = tracked(ctx)

    {method, params} = sc.failed
    snapshot = adapter_state(ctx)
    send_request(ctx, @failed, method, params)
    early = drain(ctx)

    assert [%{"error" => %{"message" => message}}] = answers(early, @failed)
    assert message =~ "write_too_large"
    assert tracked(ctx) == before, "the rejected #{method} left pending state behind"

    Enum.each(sc.late.(snapshot), &emit(ctx, &1))

    {method, params} = sc.next
    snapshot = adapter_state(ctx)
    send_request(ctx, @next, method, params)
    Enum.each(sc.reply.(snapshot), &emit(ctx, &1))
    later = collect_until(ctx, &response_to?(&1, @next))

    assert length(answers(early ++ later, @failed)) == 1,
           "the late native reply answered the failed #{method} again: " <>
             inspect(answers(early ++ later, @failed))

    assert [_answer] = answers(later, @next), "the next #{method} did not go through"
    AdapterBridge.close(ctx.bridge)
  end

  defp tracked(ctx) do
    state = adapter_state(ctx)

    case ctx.adapter do
      :claude ->
        {state.pending_prompt_id, state.pending_controls |> Map.keys() |> Enum.sort(),
         PromptQueue.to_list(state.prompt_queue)}

      adapter when adapter in [:codex, :zcode] ->
        prompts = Map.new(state.sessions, fn {id, s} -> {id, s[:active_prompt_acp_id]} end)
        queue = if adapter == :zcode, do: PromptQueue.to_list(state.prompt_queue), else: []
        {state.pending_requests, prompts, queue}

      :pi ->
        {state.pending_prompt, state.pending_controls, state.control_groups, state.op_in_flight,
         state.op_queue, PromptQueue.to_list(state.prompt_queue)}
    end
  end

  # -- scenarios ----------------------------------------------------------------

  defp scenario(ctx, "session/prompt" = route) when ctx.adapter == :claude do
    base(ctx, ClaudeSDK, cli_path: ctx.native, cwd: ctx.dir, managed: false)
    |> Map.merge(%{
      setup:
        &open_session(&1, "session/new", %{"cwd" => ctx.dir, "sessionId" => "claude-session"}, []),
      failed: {route, prompt_params("claude-session", @huge)},
      # Claude ends a turn with a result event; only a running prompt takes it.
      late: fn _state -> [claude_result("late")] end,
      next: {route, prompt_params("claude-session", "hello")},
      reply: fn _state -> [claude_result("done")] end
    })
  end

  defp scenario(ctx, "session/set_config_option" = route) when ctx.adapter == :claude do
    base(ctx, ClaudeSDK, cli_path: ctx.native, cwd: ctx.dir, managed: false)
    |> Map.merge(%{
      setup:
        &open_session(&1, "session/new", %{"cwd" => ctx.dir, "sessionId" => "claude-session"}, []),
      failed:
        {route, %{"sessionId" => "claude-session", "configId" => "model", "value" => @huge}},
      late: fn _state -> [] end,
      next: {route, %{"sessionId" => "claude-session", "configId" => "model", "value" => "opus"}},
      reply: fn _state -> [] end
    })
  end

  defp scenario(ctx, "session/new" = route) when ctx.adapter == :codex do
    codex(ctx)
    |> Map.merge(%{
      failed: {route, %{"cwd" => ctx.dir, "model" => @huge}},
      late: fn state -> [codex_thread(state.next_id, "late-thread")] end,
      next: {route, %{"cwd" => ctx.dir}},
      reply: fn state -> [codex_thread(state.next_id, "thread-1")] end
    })
  end

  defp scenario(ctx, route)
       when ctx.adapter == :codex and route in ["session/load", "session/resume"] do
    codex(ctx)
    |> Map.merge(%{
      failed: {route, %{"cwd" => ctx.dir, "sessionId" => @huge}},
      late: fn state -> [codex_thread(state.next_id, "late-thread")] end,
      next: {route, %{"cwd" => ctx.dir, "sessionId" => "thread-1"}},
      reply: fn state -> [codex_thread(state.next_id, "thread-1")] end
    })
  end

  defp scenario(ctx, "session/list" = route) when ctx.adapter == :codex do
    codex(ctx)
    |> Map.merge(%{
      failed: {route, %{"cursor" => @huge}},
      late: fn state -> [%{"id" => state.next_id, "result" => %{"data" => []}}] end,
      next: {route, %{}},
      reply: fn state -> [%{"id" => state.next_id, "result" => %{"data" => []}}] end
    })
  end

  defp scenario(ctx, "session/prompt" = route) when ctx.adapter == :codex do
    codex(ctx)
    |> Map.merge(%{
      setup: fn ctx ->
        open_session(ctx, "session/new", %{"cwd" => ctx.dir}, fn state ->
          [codex_thread(state.next_id, "thread-1")]
        end)
      end,
      failed: {route, prompt_params("thread-1", @huge)},
      late: fn state ->
        [
          %{"id" => state.next_id, "result" => %{"turn" => %{"id" => "turn-late"}}},
          codex_turn_completed("turn-late")
        ]
      end,
      next: {route, prompt_params("thread-1", "hello")},
      reply: fn state ->
        [
          %{"id" => state.next_id, "result" => %{"turn" => %{"id" => "turn-1"}}},
          codex_turn_completed("turn-1")
        ]
      end
    })
  end

  defp scenario(ctx, "authenticate" = route) when ctx.adapter == :codex do
    key = &%{"methodId" => "api-key", "_meta" => %{"api-key" => %{"apiKey" => &1}}}

    codex(ctx)
    |> Map.merge(%{
      failed: {route, key.(@huge)},
      late: fn state -> [native_error(state.next_id)] end,
      next: {route, key.("sk-test")},
      reply: fn state -> [native_error(state.next_id)] end
    })
  end

  defp scenario(ctx, "session/new" = route) when ctx.adapter == :zcode do
    # ZCode drops unknown model names, so the request grows through a long
    # (real, authorized) workspace path instead, under a lower limit.
    long =
      Enum.reduce(1..4, ctx.dir, fn i, path ->
        Path.join(path, String.duplicate("#{i}", 200))
      end)

    File.mkdir_p!(long)

    zcode(ctx, 900)
    |> Map.merge(%{
      failed: {route, %{"cwd" => long}},
      late: fn state -> [zcode_session(state.next_id, "late-session")] end,
      next: {route, %{"cwd" => ctx.dir}},
      reply: fn state -> [zcode_session(state.next_id, "zcode-1")] end
    })
  end

  defp scenario(ctx, route)
       when ctx.adapter == :zcode and route in ["session/load", "session/resume"] do
    zcode(ctx)
    |> Map.merge(%{
      failed: {route, %{"cwd" => ctx.dir, "sessionId" => @huge}},
      # A resume also subscribes, so it takes two native ids.
      late: fn state ->
        [
          zcode_session(state.next_id, "late-session"),
          %{"id" => state.next_id + 1, "result" => %{}}
        ]
      end,
      next: {route, %{"cwd" => ctx.dir, "sessionId" => "zcode-1"}},
      reply: fn state -> [zcode_session(state.next_id, "zcode-1")] end
    })
  end

  defp scenario(ctx, "session/list" = route) when ctx.adapter == :zcode do
    zcode(ctx)
    |> Map.merge(%{
      failed: {route, %{"cursor" => @huge}},
      late: fn state -> [%{"id" => state.next_id, "result" => %{"sessions" => []}}] end,
      next: {route, %{}},
      reply: fn state -> [%{"id" => state.next_id, "result" => %{"sessions" => []}}] end
    })
  end

  defp scenario(ctx, "session/fork" = route) when ctx.adapter == :zcode do
    zcode(ctx)
    |> Map.merge(%{
      failed: {route, %{"cwd" => ctx.dir, "sessionId" => @huge}},
      late: fn state -> [native_error(state.next_id)] end,
      next: {route, %{"cwd" => ctx.dir, "sessionId" => "zcode-1"}},
      reply: fn state -> [native_error(state.next_id)] end
    })
  end

  # Close answers at once; the native close it tracks must not outlive the write.
  defp scenario(ctx, "session/close" = route) when ctx.adapter == :zcode do
    zcode(ctx)
    |> Map.merge(%{
      failed: {route, %{"sessionId" => @huge}},
      late: fn state -> [%{"id" => state.next_id, "result" => %{}}] end,
      next: {route, %{"sessionId" => "zcode-1"}},
      reply: fn _state -> [] end
    })
  end

  defp scenario(ctx, "session/prompt" = route) when ctx.adapter == :zcode do
    zcode(ctx)
    |> Map.merge(%{
      setup: fn ctx ->
        open_session(ctx, "session/new", %{"cwd" => ctx.dir}, fn state ->
          [zcode_session(state.next_id, "zcode-1")]
        end)
      end,
      failed: {route, prompt_params("zcode-1", @huge)},
      late: fn state -> [native_error(state.next_id), zcode_turn_completed()] end,
      next: {route, prompt_params("zcode-1", "hello")},
      reply: fn state -> [%{"id" => state.next_id, "result" => %{}}, zcode_turn_completed()] end
    })
  end

  defp scenario(ctx, "session/prompt" = route) when ctx.adapter == :pi do
    pi(ctx)
    |> Map.merge(%{
      failed: {route, prompt_params("N1", @huge)},
      late: fn state ->
        {msg_id, _counter} = RPC.next_prompt_id(state.msg_counter)
        [pi_response(msg_id, "prompt", %{}), %{"type" => "agent_settled"}]
      end,
      next: {route, prompt_params("N1", "hello")},
      reply: fn state ->
        {msg_id, _counter} = RPC.next_prompt_id(state.msg_counter)
        [pi_response(msg_id, "prompt", %{}), %{"type" => "agent_settled"}]
      end
    })
  end

  defp scenario(ctx, "slash command") when ctx.adapter == :pi do
    pi(ctx)
    |> Map.merge(%{
      failed: {"session/prompt", prompt_params("N1", "/name " <> @huge)},
      late: fn state ->
        {rpc_id, _counter} = RPC.next_rpc_id(state.rpc_counter)
        [pi_response(rpc_id, "set_session_name", %{})]
      end,
      next: {"session/prompt", prompt_params("N1", "/name short")},
      reply: fn state ->
        {rpc_id, _counter} = RPC.next_rpc_id(state.rpc_counter)
        [pi_response(rpc_id, "set_session_name", %{})]
      end
    })
  end

  defp scenario(ctx, "session/resume" = route) when ctx.adapter == :pi do
    # The session map points "far" at a file whose path does not fit a write.
    sessions = Path.join(ctx.dir, "sessions")
    File.mkdir_p!(sessions)
    near = Path.join(sessions, "near.jsonl")
    File.write!(near, "")

    File.write!(
      Path.join(ctx.dir, "session-map.json"),
      Jason.encode!(%{
        "version" => 1,
        "sessions" => %{
          "far" => %{"sessionId" => "far", "cwd" => ctx.dir, "sessionFile" => "/" <> @huge},
          "near" => %{"sessionId" => "near", "cwd" => ctx.dir, "sessionFile" => near}
        }
      })
    )

    pi(ctx)
    |> Map.merge(%{
      failed: {route, %{"cwd" => ctx.dir, "sessionId" => "far"}},
      late: fn state ->
        {rpc_id, _counter} = RPC.next_rpc_id(state.rpc_counter)
        [pi_response(rpc_id, "switch_session", %{"cancelled" => false})]
      end,
      next: {route, %{"cwd" => ctx.dir, "sessionId" => "near"}},
      reply: fn state -> pi_setup_replies(state, "near", near) end
    })
  end

  defp base(ctx, adapter_mod, opts, limit \\ @limit) do
    ctx
    |> Map.put(:adapter_mod, adapter_mod)
    |> Map.put(:opts, Keyword.put(opts, :max_write_bytes, limit))
    |> Map.put(:setup, & &1)
  end

  defp codex(ctx),
    do: base(ctx, Codex, codex_path: ctx.native, cwd: ctx.dir, allow_unbound_threads: true)

  defp zcode(ctx, limit \\ @limit),
    do: base(ctx, ZCode, [cli_path: ctx.native, cwd: ctx.dir], limit)

  defp pi(ctx) do
    opts = [
      cli_path: ctx.native,
      cwd: ctx.dir,
      agent_dir: Path.join(ctx.dir, "agent"),
      session_dir: Path.join(ctx.dir, "sessions"),
      session_map_path: Path.join(ctx.dir, "session-map.json"),
      update_notice: false
    ]

    base(%{ctx | adapter: :pi}, UnmanagedPi, opts)
    |> Map.put(:setup, fn ctx ->
      open_session(ctx, "session/new", %{"cwd" => ctx.dir}, fn state ->
        file = Path.join([ctx.dir, "sessions", "N1.jsonl"])
        pi_setup_replies(state, "N1", file)
      end)
    end)
  end

  # Pi answers the change first; the adapter then sends its four queries.
  defp pi_setup_replies(state, session_id, file) do
    {change, counter} = RPC.next_rpc_id(state.rpc_counter)
    {ids, _counter} = Enum.map_reduce(1..4, counter, fn _i, c -> RPC.next_rpc_id(c) end)
    [state_id, models_id, levels_id, commands_id] = ids
    change_type = if session_id == "N1", do: "new_session", else: "switch_session"

    [
      pi_response(change, change_type, %{"cancelled" => false}),
      pi_response(state_id, "get_state", %{"sessionId" => session_id, "sessionFile" => file}),
      pi_response(models_id, "get_available_models", %{
        "models" => [%{"provider" => "fake", "id" => "m1", "name" => "M1"}]
      }),
      pi_response(levels_id, "get_available_thinking_levels", %{"levels" => ["off", "high"]}),
      pi_response(commands_id, "get_commands", %{"commands" => []})
    ]
  end

  # -- native messages ------------------------------------------------------------

  defp claude_result(text),
    do: %{"type" => "result", "subtype" => "success", "result" => text, "is_error" => false}

  defp codex_thread(id, thread_id),
    do: %{"id" => id, "result" => %{"thread" => %{"id" => thread_id}}}

  defp codex_turn_completed(turn_id) do
    %{
      "method" => "turn/completed",
      "params" => %{
        "threadId" => "thread-1",
        "turn" => %{"id" => turn_id, "status" => "completed"}
      }
    }
  end

  defp zcode_session(id, session_id),
    do: %{"id" => id, "result" => %{"session" => %{"sessionId" => session_id}}}

  defp zcode_turn_completed do
    %{
      "method" => "session/event",
      "params" => %{
        "sessionId" => "zcode-1",
        "type" => "turn.completed",
        "resultType" => "success"
      }
    }
  end

  defp native_error(id),
    do: %{"id" => id, "error" => %{"code" => -1, "message" => "native error"}}

  defp pi_response(id, command, data),
    do: %{
      "type" => "response",
      "id" => id,
      "command" => command,
      "success" => true,
      "data" => data
    }

  defp prompt_params(session_id, text),
    do: %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => text}]}

  # -- bridge helpers -------------------------------------------------------------

  defp start(sc) do
    {:ok, bridge} = AdapterBridge.start_link(adapter: sc.adapter_mod, adapter_opts: sc.opts)
    _ = drain(%{bridge: bridge})
    Map.put(sc, :bridge, bridge)
  end

  defp open_session(ctx, method, params, replies) do
    snapshot = adapter_state(ctx)
    send_request(ctx, 1, method, params)
    replies = if is_function(replies, 1), do: replies.(snapshot), else: replies
    Enum.each(replies, &emit(ctx, &1))
    assert [%{"result" => _}] = answers(collect_until(ctx, &response_to?(&1, 1)), 1)
    ctx
  end

  defp adapter_state(ctx), do: :sys.get_state(ctx.bridge).adapter_state

  defp send_request(ctx, id, method, params) do
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    assert :ok = AdapterBridge.send_message(ctx.bridge, Jason.encode!(message))
  end

  defp emit(ctx, message) do
    assert :ok = PortRunner.command(native_port(ctx), ["__emit__ ", Jason.encode!(message), "\n"])
  end

  # The bridge owns the native process, unless the adapter manages its own.
  defp native_port(ctx) do
    state = :sys.get_state(ctx.bridge)
    state.port || state.adapter_state.port
  end

  defp drain(ctx) do
    case AdapterBridge.receive_message(ctx.bridge, 0) do
      {:ok, raw} -> [Jason.decode!(raw) | drain(ctx)]
      {:error, _reason} -> []
    end
  end

  # Reads until a message satisfies `done?`, or for two seconds.
  defp collect_until(ctx, done?) do
    case AdapterBridge.receive_message(ctx.bridge, 2_000) do
      {:ok, raw} ->
        message = Jason.decode!(raw)

        if done?.(message),
          do: [message | drain(ctx)],
          else: [message | collect_until(ctx, done?)]

      {:error, _reason} ->
        []
    end
  end

  defp answers(messages, id), do: Enum.filter(messages, &response_to?(&1, id))

  defp response_to?(message, id),
    do: message["id"] == id and not Map.has_key?(message, "method")
end
