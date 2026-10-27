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
  use ExUnit.Case, async: true

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

    File.write!(native, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        "__emit__ "*) printf '%s\\n' "${line#__emit__ }" ;;
      esac
    done
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
    base(ctx, ClaudeSDK, cli_path: ctx.native, cwd: ctx.dir)
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
    base(ctx, ClaudeSDK, cli_path: ctx.native, cwd: ctx.dir)
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

  defp codex(ctx), do: base(ctx, Codex, codex_path: ctx.native, cwd: ctx.dir)

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
    port = :sys.get_state(ctx.bridge).port
    assert :ok = PortRunner.command(port, ["__emit__ ", Jason.encode!(message), "\n"])
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
