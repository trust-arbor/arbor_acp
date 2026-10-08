defmodule Arbor.ACP.AdapterBridge do
  @moduledoc """
  GenServer bridge between ACP clients and non-native CLI agents.

  Owns a shared subprocess handle and delegates translation to a pluggable
  `Arbor.ACP.Adapter` implementation. Uses an outbox + waiters queue
  for synchronized message delivery.

  ## Modes

  - **Persistent** (default) — opens an owned subprocess on init, keeps it alive
  - **One-shot** — adapter manages subprocess per prompt (Codex pattern)
  - **Adapter-managed** — adapter owns one or more persistent subprocess handles

  Pending output is bounded by both `:max_outbox_messages` (1,024 by default)
  and `:max_outbox_bytes` (4 MiB by default). `:max_one_shot_tasks` defaults to 8.
  Persistent subprocess frames are acknowledged after output admission. Explicit
  `close/1` returns a cleanup error when the owned subprocess cannot be cleaned
  within its finite budget.

  ## Usage

      {:ok, bridge} = AdapterBridge.start_link(
        adapter: Arbor.ACP.Adapters.ClaudeSDK,
        adapter_opts: [model: "sonnet"]
      )

      :ok = AdapterBridge.send_message(bridge, json_rpc_string)
      {:ok, response} = AdapterBridge.receive_message(bridge)
  """

  use GenServer

  alias Arbor.ACP.AdapterSupport.Subprocess, as: PortRunner
  alias Arbor.ACP.Capabilities
  alias Arbor.ACP.Envelope
  alias Arbor.ACP.Meta
  alias Arbor.ACP.Internal.Maps
  alias Arbor.ACP.Internal.Options
  alias Arbor.RPC.Subprocess, as: SharedSubprocess

  @type t :: GenServer.server()
  @default_max_buffer_bytes 1_048_576
  @default_max_outbox_messages 1_024
  @default_max_outbox_bytes 4_194_304
  @default_max_waiters 128
  @default_max_one_shot_tasks 8

  defstruct [
    :adapter_mod,
    :adapter_state,
    :adapter_opts,
    :port,
    :port_generation,
    :port_monitor,
    :outbox,
    :waiters,
    max_buffer_bytes: @default_max_buffer_bytes,
    max_outbox_messages: @default_max_outbox_messages,
    max_outbox_bytes: @default_max_outbox_bytes,
    outbox_bytes: 0,
    max_waiters: @default_max_waiters,
    max_one_shot_tasks: @default_max_one_shot_tasks,
    one_shot_tasks: %{},
    one_shot_monitors: %{},
    buffer: "",
    native_events: :off,
    native_sequence: 0,
    adapter_name: nil,
    cleanup_result: :ok,
    status: :connecting
  ]

  # Public API

  @doc "Start the bridge linked to the caller."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, bridge_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, bridge_opts, gen_opts)
  end

  @doc "Send a JSON-encoded ACP message to the agent."
  @spec send_message(t(), String.t()) :: :ok | {:error, term()}
  def send_message(bridge, json) do
    GenServer.call(bridge, {:send, json})
  end

  @doc """
  Receive the next ACP message from the agent. Blocks until available.

  A finite deadline starts in the caller, so a timed-out call cannot consume
  buffered output when the bridge resumes. Timeout zero polls only messages
  buffered before the poll, with a small bounded scheduling allowance.
  """
  @spec receive_message(t(), timeout()) :: {:ok, String.t()} | {:error, term()}
  def receive_message(bridge, timeout \\ 30_000)

  def receive_message(bridge, :infinity) do
    GenServer.call(bridge, {:receive, :infinity, :infinity, false}, :infinity)
  end

  def receive_message(bridge, timeout) when is_integer(timeout) and timeout >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout

    GenServer.call(
      bridge,
      {:receive, deadline, deadline + 10, timeout == 0},
      max(timeout, 1) + 10
    )
  end

  def receive_message(_bridge, _timeout), do: {:error, :invalid_timeout}

  @doc "Close the bridge and terminate the subprocess."
  @spec close(t()) :: :ok | {:error, term()}
  def close(bridge) do
    GenServer.call(bridge, :close)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    adapter_mod = Keyword.fetch!(opts, :adapter)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    {:ok, adapter_state} = adapter_mod.init(adapter_opts)

    state = %__MODULE__{
      adapter_mod: adapter_mod,
      adapter_state: adapter_state,
      adapter_opts: adapter_opts,
      adapter_name: adapter_name(adapter_mod),
      native_events: native_events_option(opts),
      outbox: :queue.new(),
      waiters: :queue.new(),
      max_buffer_bytes:
        Options.positive_integer(opts, :max_buffer_bytes, @default_max_buffer_bytes),
      max_outbox_messages:
        Options.positive_integer(opts, :max_outbox_messages, @default_max_outbox_messages),
      max_outbox_bytes:
        Options.positive_integer(opts, :max_outbox_bytes, @default_max_outbox_bytes),
      max_waiters: Options.positive_integer(opts, :max_waiters, @default_max_waiters),
      max_one_shot_tasks:
        Options.positive_integer(opts, :max_one_shot_tasks, @default_max_one_shot_tasks)
    }

    case adapter_mod.command(adapter_opts) do
      :one_shot ->
        # One-shot adapters don't open a Port on init
        # Init response is synthesized when the Client sends the initialize request
        {:ok, %{state | status: :ready}}

      :adapter_managed ->
        {:ok, %{state | status: :ready}}

      {:error, reason} ->
        {:stop, reason}

      {cmd, args} ->
        case open_port(cmd, args, adapter_opts, adapter_mod, state.max_buffer_bytes) do
          {:ok, port} ->
            [actor] = SharedSubprocess.linked_processes(port)

            state = %{
              state
              | port: port,
                port_generation: PortRunner.identity(port),
                port_monitor: Process.monitor(actor),
                status: :ready
            }

            case maybe_post_connect(state) do
              {:ok, state} ->
                {:ok, state}

              {:error, reason, state} ->
                do_close(state)
                {:stop, {:post_connect_write_failed, reason}}
            end

          {:error, reason} ->
            {:stop, reason}
        end
    end
  end

  @impl true
  def handle_call({:send, _json}, _from, %{status: :closed} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:send, json}, _from, state)
      when is_binary(json) and byte_size(json) > state.max_buffer_bytes do
    {:reply, {:error, :frame_too_large}, state}
  end

  def handle_call({:send, json}, from, state) do
    case Jason.decode(json) do
      {:ok, msg} ->
        method = msg["method"]

        if method do
          :telemetry.execute(
            [:arbor_acp, :request, :received],
            %{system_time: System.system_time()},
            %{method: method}
          )
        end

        result = handle_outbound(msg, json, from, state)

        if method do
          :telemetry.execute(
            [:arbor_acp, :request, :completed],
            %{system_time: System.system_time()},
            %{method: method}
          )
        end

        result

      {:error, reason} ->
        {:reply, {:error, {:decode_error, reason}}, state}
    end
  end

  def handle_call({:receive, waiter_deadline, acceptance_deadline, immediate}, from, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      acceptance_deadline != :infinity and now >= acceptance_deadline ->
        {:reply, {:error, :timeout}, state}

      not immediate and waiter_deadline != :infinity and now >= waiter_deadline ->
        {:reply, {:error, :timeout}, state}

      immediate and not :queue.is_empty(state.outbox) and
          not buffered_before?(state.outbox, waiter_deadline) ->
        {:reply, {:error, :timeout}, state}

      true ->
        receive_output(state, from, waiter_deadline, immediate)
    end
  end

  def handle_call(:close, _from, state) do
    state = do_close(state)
    {:stop, :normal, state.cleanup_result, state}
  end

  @impl true
  def handle_info(
        {:arbor_rpc, generation, {:frame, token, line}},
        %{port_generation: generation, port: port} = state
      )
      when port != nil do
    state = translate_port_line(state, line)
    {:noreply, acknowledge_frame(state, {port, token})}
  end

  def handle_info(
        {:arbor_rpc, generation, {:closed, reason, remainder}},
        %{port_generation: generation, port: port} = state
      )
      when port != nil do
    {:noreply, close_stream(state, reason, remainder)}
  end

  # A closed or superseded persistent child cannot feed another connection.
  # Adapter-managed events are routed through the adapter's receipt callback.
  def handle_info({:arbor_rpc, _generation, _event}, %{port_generation: generation} = state)
      when generation != nil,
      do: {:noreply, state}

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info({:one_shot_result, token, messages}, state) do
    case Map.pop(state.one_shot_tasks, token) do
      {nil, _tasks} ->
        {:noreply, state}

      {%{monitor_ref: monitor_ref}, tasks} ->
        Process.demonitor(monitor_ref, [:flush])

        state = %{
          state
          | one_shot_tasks: tasks,
            one_shot_monitors: Map.delete(state.one_shot_monitors, monitor_ref)
        }

        {:noreply, push_messages(state, messages)}
    end
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, _pid, _reason},
        %{port_monitor: monitor_ref} = state
      )
      when monitor_ref != nil do
    {:noreply, state |> clear_port() |> reply_error_to_waiters(:port_closed)}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason} = message, state) do
    case Map.pop(state.one_shot_monitors, monitor_ref) do
      {nil, _monitors} ->
        {:noreply, handle_adapter_message(message, state)}

      {token, monitors} ->
        {:noreply,
         %{
           state
           | one_shot_tasks: Map.delete(state.one_shot_tasks, token),
             one_shot_monitors: monitors
         }}
    end
  end

  def handle_info({:waiter_timeout, token}, state) do
    {:noreply, %{state | waiters: delete_waiter(state.waiters, token)}}
  end

  def handle_info(msg, state) do
    {:noreply, handle_adapter_message(msg, state)}
  end

  @impl true
  def terminate(_reason, state) do
    do_close(state)
    :ok
  end

  # Private helpers

  defp receive_output(state, from, waiter_deadline, immediate) do
    case :queue.out(state.outbox) do
      {{:value, {message, _received_at}}, rest} ->
        {:reply, {:ok, message},
         %{state | outbox: rest, outbox_bytes: state.outbox_bytes - byte_size(message)}}

      {:empty, _} ->
        cond do
          state.status == :closed ->
            {:reply, {:error, :closed}, state}

          immediate ->
            {:reply, {:error, :timeout}, state}

          true ->
            register_waiter(state, from, waiter_deadline)
        end
    end
  end

  defp register_waiter(state, from, waiter_deadline) do
    waiters = prune_dead_waiters(state.waiters)

    if :queue.len(waiters) >= state.max_waiters do
      {:reply, {:error, :too_many_waiters}, %{state | waiters: waiters}}
    else
      token = make_ref()
      timer_ref = schedule_waiter_timeout(token, deadline_remaining(waiter_deadline))

      waiter = %{
        from: from,
        token: token,
        timer_ref: timer_ref,
        deadline: waiter_deadline
      }

      {:noreply, %{state | waiters: :queue.in(waiter, waiters)}}
    end
  end

  defp open_port(cmd, args, opts, adapter_mod, max_frame_bytes) do
    opts = opts |> Keyword.put(:owner, self()) |> Keyword.put(:max_frame_bytes, max_frame_bytes)
    PortRunner.open(cmd, args, opts, adapter_mod)
  end

  defp synthesize_result(state, request_id, result) do
    push_message(state, request_id |> Envelope.response(result) |> Jason.encode!())
  end

  defp synthesize_error(state, request_id, code, message) do
    push_message(state, request_id |> Envelope.error(code, message) |> Jason.encode!())
  end

  defp synthesize_init_response(state, request_id) do
    caps =
      if function_exported?(state.adapter_mod, :capabilities, 0) do
        state.adapter_mod.capabilities()
      else
        %{}
      end

    caps = maybe_add_adapter_session_capabilities(caps, state.adapter_mod)

    init_result =
      Envelope.response(request_id, %{
        "agentInfo" => %{
          "name" => adapter_name(state.adapter_mod),
          "version" => "1.0.0"
        },
        "agentCapabilities" => caps,
        "authMethods" => adapter_auth_methods(state),
        "protocolVersion" => 1
      })

    push_message(state, Jason.encode!(init_result))
  end

  defp maybe_add_adapter_session_capabilities(caps, adapter_mod) do
    Capabilities.advertise_adapter_session_list(caps, adapter_mod)
    |> Capabilities.advertise_adapter_session_fork(adapter_mod)
  end

  defp advertised_capabilities(state) do
    if function_exported?(state.adapter_mod, :capabilities, 0) do
      state.adapter_mod.capabilities()
    else
      %{}
    end
    |> maybe_add_adapter_session_capabilities(state.adapter_mod)
  end

  defp ensure_capability(state, :load_session),
    do: state |> advertised_capabilities() |> Capabilities.supported?(:load_session)

  defp ensure_capability(state, :logout),
    do: state |> advertised_capabilities() |> Capabilities.supported?(:logout)

  defp ensure_capability(state, :session_list),
    do: state |> advertised_capabilities() |> Capabilities.supported?(:session_list)

  defp ensure_capability(state, :session_resume),
    do: state |> advertised_capabilities() |> Capabilities.supported?(:session_resume)

  defp ensure_capability(state, :session_close),
    do: state |> advertised_capabilities() |> Capabilities.supported?(:session_close)

  defp ensure_capability(state, :session_delete),
    do: state |> advertised_capabilities() |> Capabilities.supported?(:session_delete)

  defp ensure_capability(state, :session_fork),
    do: state |> advertised_capabilities() |> Capabilities.supported?(:session_fork)

  defp adapter_auth_methods(state) do
    cond do
      function_exported?(state.adapter_mod, :auth_methods, 2) ->
        state.adapter_mod.auth_methods(state.adapter_opts, state.adapter_state)

      function_exported?(state.adapter_mod, :auth_methods, 1) ->
        state.adapter_mod.auth_methods(state.adapter_opts)

      true ->
        []
    end
  end

  defp reject_unsupported_method(state, id, method) do
    synthesize_error(state, id, -32_601, "Method not found: #{method}")
  end

  defp session_result(state, session_id) do
    state
    |> session_state_result()
    |> Map.put("sessionId", session_id)
  end

  defp session_state_result(state) do
    %{}
    |> Maps.put_non_empty("modes", session_modes(state))
    |> Maps.put_non_empty("configOptions", adapter_config_options(state))
  end

  defp config_options_result(state) do
    %{"configOptions" => adapter_config_options(state)}
  end

  defp session_modes(state) do
    if function_exported?(state.adapter_mod, :modes, 0) do
      case state.adapter_mod.modes() do
        [] -> nil
        modes -> %{"availableModes" => modes, "currentModeId" => current_mode_id(modes)}
      end
    end
  end

  defp adapter_config_options(state) do
    if function_exported?(state.adapter_mod, :config_options, 0) do
      state.adapter_mod.config_options()
    else
      []
    end
  end

  defp current_mode_id([%{"id" => id} | _]), do: id
  defp current_mode_id([%{id: id} | _]), do: id
  defp current_mode_id(_), do: nil

  defp maybe_post_connect(%{adapter_mod: adapter_mod, adapter_state: adapter_state} = state) do
    if function_exported?(adapter_mod, :post_connect, 1) do
      case adapter_mod.post_connect(adapter_state) do
        {:ok, data, new_adapter_state} ->
          state = %{state | adapter_state: new_adapter_state}

          case write_to_port(state, data) do
            :ok -> {:ok, state}
            {:error, reason} -> {:error, reason, state}
          end

        {:ok, new_adapter_state} ->
          {:ok, %{state | adapter_state: new_adapter_state}}
      end
    else
      {:ok, state}
    end
  end

  # The adapter's own `name/0` when it has one; otherwise the module's last
  # segment in lower case. Used for agentInfo.name and `_meta.ex_mcp.native`.
  defp adapter_name(mod) do
    if function_exported?(mod, :name, 0) do
      mod.name()
    else
      mod
      |> Module.split()
      |> List.last()
      |> String.downcase()
    end
  end

  # Synthesize responses for ACP methods that adapted agents don't handle natively.
  # The Client sends these as normal JSON-RPC requests and expects matching responses.

  defp handle_outbound(%{"method" => "authenticate", "id" => id} = msg, _json, _from, state) do
    # Delegate to adapter. If it writes to the native process, the adapter is
    # responsible for producing the eventual ACP response from the native
    # response. A plain `:skip` is not a successful authentication.
    msg
    |> translate_outbound_message(state)
    |> handle_authenticate_translation_result(msg, id)
  end

  defp handle_outbound(%{"method" => "logout", "id" => id} = msg, _json, _from, state) do
    if ensure_capability(state, :logout) do
      synthesize_after_translate(msg, id, state, fn _state -> %{} end)
    else
      {:reply, :ok, reject_unsupported_method(state, id, "logout")}
    end
  end

  defp handle_outbound(%{"method" => "initialize", "id" => id} = msg, _json, _from, state) do
    case state.adapter_mod.translate_outbound(msg, state.adapter_state) do
      {:ok, :skip, new_adapter_state} ->
        state = %{state | adapter_state: new_adapter_state}
        state = synthesize_init_response(state, id)
        {:reply, :ok, state}

      {:ok, :pending, new_adapter_state} ->
        state = %{state | adapter_state: new_adapter_state}
        {:reply, :ok, state}

      {:ok, data, new_adapter_state} ->
        state = %{state | adapter_state: new_adapter_state}

        case write_to_port(state, data) do
          :ok -> {:reply, :ok, synthesize_init_response(state, id)}
          {:error, reason} -> reply_translation_error(msg, reason, state)
        end

      {:reply, _result, new_adapter_state} ->
        state = %{state | adapter_state: new_adapter_state}
        state = synthesize_init_response(state, id)
        {:reply, :ok, state}
    end
  end

  defp handle_outbound(%{"method" => "session/new", "id" => id} = msg, _json, _from, state) do
    msg
    |> translate_lifecycle(state)
    |> apply_lifecycle_translation(id, state, -32_602, fn state ->
      session_result(state, "session_#{System.unique_integer([:positive])}")
    end)
  end

  defp handle_outbound(%{"method" => "session/load", "id" => id} = msg, _json, _from, state) do
    if ensure_capability(state, :load_session) do
      msg
      |> translate_lifecycle(state)
      |> apply_lifecycle_translation(id, state, -32_603, &session_state_result/1)
    else
      {:reply, :ok, reject_unsupported_method(state, id, "session/load")}
    end
  end

  defp handle_outbound(%{"method" => "session/resume", "id" => id} = msg, _json, _from, state) do
    if ensure_capability(state, :session_resume) do
      msg
      |> translate_lifecycle(state)
      |> apply_lifecycle_translation(id, state, -32_603, &session_state_result/1)
    else
      {:reply, :ok, reject_unsupported_method(state, id, "session/resume")}
    end
  end

  defp handle_outbound(%{"method" => "session/fork", "id" => id} = msg, _json, _from, state) do
    cond do
      not ensure_capability(state, :session_fork) ->
        {:reply, :ok, reject_unsupported_method(state, id, "session/fork")}

      function_exported?(state.adapter_mod, :fork_session, 2) ->
        handle_adapter_fork_callback(msg, id, state)

      true ->
        msg
        |> translate_outbound_message(state)
        |> handle_fork_translation(id)
    end
  end

  defp handle_outbound(%{"method" => "session/close", "id" => id} = msg, _json, _from, state) do
    if ensure_capability(state, :session_close) do
      synthesize_after_translate(msg, id, state, fn _state -> %{} end)
    else
      {:reply, :ok, reject_unsupported_method(state, id, "session/close")}
    end
  end

  defp handle_outbound(%{"method" => "session/delete", "id" => id} = msg, _json, _from, state) do
    if ensure_capability(state, :session_delete) do
      synthesize_after_translate(msg, id, state, fn _state -> %{} end)
    else
      {:reply, :ok, reject_unsupported_method(state, id, "session/delete")}
    end
  end

  defp handle_outbound(%{"method" => "session/list", "id" => id} = msg, _json, _from, state) do
    cond do
      not ensure_capability(state, :session_list) ->
        {:reply, :ok, reject_unsupported_method(state, id, "session/list")}

      function_exported?(state.adapter_mod, :list_sessions, 2) ->
        params = Map.get(msg, "params", %{})

        case state.adapter_mod.list_sessions(params, state.adapter_state) do
          {:ok, result, new_adapter_state} ->
            state = %{state | adapter_state: new_adapter_state}
            state = synthesize_result(state, id, list_sessions_result(result))
            {:reply, :ok, state}

          {:error, reason, new_adapter_state} ->
            state = %{state | adapter_state: new_adapter_state}
            state = synthesize_error(state, id, -32_603, to_string(reason))
            {:reply, :ok, state}
        end

      true ->
        # Let translate_outbound handle it (may send to native agent or skip)
        case state.adapter_mod.translate_outbound(msg, state.adapter_state) do
          {:ok, :skip, new_adapter_state} ->
            state = %{state | adapter_state: new_adapter_state}
            state = synthesize_result(state, id, %{"sessions" => []})
            {:reply, :ok, state}

          {:ok, :pending, new_adapter_state} ->
            {:reply, :ok, %{state | adapter_state: new_adapter_state}}

          {:ok, data, new_adapter_state} ->
            state = %{state | adapter_state: new_adapter_state}

            case write_to_port(state, data) do
              :ok -> {:reply, :ok, state}
              {:error, reason} -> reply_translation_error(msg, reason, state)
            end

          {:reply, result, new_adapter_state} ->
            state = %{state | adapter_state: new_adapter_state}
            state = synthesize_result(state, id, result || %{"sessions" => []})
            {:reply, :ok, state}
        end
    end
  end

  defp handle_outbound(
         %{"method" => "session/set_mode", "id" => id} = msg,
         _json,
         _from,
         state
       ) do
    # Delegate to adapter — it may translate to a native command or handle in state
    synthesize_after_translate(msg, id, state, fn _state -> %{} end)
  end

  defp handle_outbound(
         %{"method" => "session/set_model", "id" => id} = msg,
         _json,
         _from,
         state
       ) do
    case translate_outbound_message(msg, state) do
      {:ok, :skip, state} ->
        {:reply, :ok, synthesize_error(state, id, -32_601, "Method not found: session/set_model")}

      translated ->
        synthesize_after_translated(translated, msg, id, fn _state -> %{} end)
    end
  end

  defp handle_outbound(
         %{"method" => "session/set_config_option", "id" => _id} = msg,
         _json,
         _from,
         state
       ) do
    msg
    |> then(&state.adapter_mod.translate_outbound(&1, state.adapter_state))
    |> config_option_parts()
    |> apply_config_option_translation(msg, state)
  end

  defp handle_outbound(msg, _json, _from, state) do
    msg
    |> translate_outbound_message(state)
    |> handle_translated_outbound(msg)
  end

  # JSON-RPC -32602 = Invalid params. A config value outside the adapter's
  # enum (e.g. Pi's thinking_level) is invalid params from the client's
  # perspective.
  defp apply_config_option_translation({:error, reason, adapter_state}, %{"id" => id}, state) do
    state = %{state | adapter_state: adapter_state}
    {:reply, :ok, synthesize_error(state, id, -32_602, to_string(reason))}
  end

  defp apply_config_option_translation({:pending_and_write, data, adapter_state}, msg, state) do
    case write_pending_translation(msg, data, adapter_state, state) do
      {:pending_and_write, :sent, state} -> {:reply, :ok, state}
      {:error, reason, state} -> reply_translation_error(msg, reason, state)
    end
  end

  defp apply_config_option_translation(
         {:ok, messages, result, data, adapter_state},
         %{"id" => id},
         state
       ) do
    state = %{state | adapter_state: adapter_state}

    case optional_write(state, data) do
      :ok ->
        state = push_encoded_messages(state, messages)
        {:reply, :ok, synthesize_result(state, id, result || config_options_result(state))}

      {:error, reason} ->
        reply_translation_error(%{"id" => id}, reason, state)
    end
  end

  # One shape per translation: messages to push, a result or nil, and a write
  # or nil. `{:ok, :skip, _}` is the adapter declining without a write.
  defp config_option_parts({:pending_and_write, data, adapter_state}),
    do: {:pending_and_write, data, adapter_state}

  defp config_option_parts({:ok, :skip, adapter_state}), do: {:ok, [], nil, nil, adapter_state}
  defp config_option_parts({:ok, data, adapter_state}), do: {:ok, [], nil, data, adapter_state}

  defp config_option_parts({:reply, result, adapter_state}),
    do: {:ok, [], result, nil, adapter_state}

  defp config_option_parts({:messages_and_reply, messages, result, adapter_state}),
    do: {:ok, messages, result, nil, adapter_state}

  defp config_option_parts({:reply_and_write, result, data, adapter_state}),
    do: {:ok, [], result, data, adapter_state}

  defp config_option_parts({:messages_and_write, messages, data, adapter_state}),
    do: {:ok, messages, nil, data, adapter_state}

  defp config_option_parts(
         {:messages_and_reply_and_write, messages, result, data, adapter_state}
       ),
       do: {:ok, messages, result, data, adapter_state}

  defp config_option_parts({:error, reason, adapter_state}), do: {:error, reason, adapter_state}

  defp handle_authenticate_translation_result({:ok, :skip, state}, _msg, id) do
    if adapter_auth_methods(state) == [] do
      {:reply, :ok, reject_unsupported_method(state, id, "authenticate")}
    else
      {:reply, :ok, synthesize_error(state, id, -32_602, "Unsupported authenticate request")}
    end
  end

  defp handle_authenticate_translation_result({:ok, _sent, state}, _msg, _id),
    do: {:reply, :ok, state}

  defp handle_authenticate_translation_result({:reply, result, state}, _msg, id),
    do: {:reply, :ok, synthesize_result(state, id, result || %{})}

  defp handle_authenticate_translation_result({:messages, messages, state}, _msg, id) do
    state = push_messages(state, Enum.map(messages, &Jason.encode!/1))
    {:reply, :ok, synthesize_result(state, id, %{})}
  end

  defp handle_authenticate_translation_result(
         {:messages_and_reply, messages, result, state},
         _msg,
         id
       ) do
    state = push_messages(state, Enum.map(messages, &Jason.encode!/1))
    {:reply, :ok, synthesize_result(state, id, result || %{})}
  end

  defp handle_authenticate_translation_result(
         {:reply_and_write, result, _delivery, state},
         _msg,
         id
       ),
       do: {:reply, :ok, synthesize_result(state, id, result || %{})}

  defp handle_authenticate_translation_result(
         {:messages_and_write, messages, _delivery, state},
         _msg,
         id
       ) do
    state = push_messages(state, Enum.map(messages, &Jason.encode!/1))
    {:reply, :ok, synthesize_result(state, id, %{})}
  end

  defp handle_authenticate_translation_result({:error, reason, state}, msg, _id),
    do: reply_translation_error(msg, reason, state)

  defp handle_adapter_fork_callback(msg, id, state) do
    params = Map.get(msg, "params", %{})

    case state.adapter_mod.fork_session(params, state.adapter_state) do
      {:ok, result, adapter_state} ->
        state = %{state | adapter_state: adapter_state}
        {:reply, :ok, synthesize_session_lifecycle_result(state, id, result)}

      {:error, {:invalid_params, reason}, adapter_state} ->
        state = %{state | adapter_state: adapter_state}
        {:reply, :ok, synthesize_error(state, id, -32_602, to_string(reason))}

      {:error, reason, adapter_state} ->
        state = %{state | adapter_state: adapter_state}
        {:reply, :ok, synthesize_error(state, id, -32_603, to_string(reason))}
    end
  end

  defp handle_fork_translation({:ok, :skip, state}, id),
    do: {:reply, :ok, synthesize_result(state, id, session_state_result(state))}

  defp handle_fork_translation({:ok, _delivery, state}, _id), do: {:reply, :ok, state}

  defp handle_fork_translation({:messages, messages, state}, id) do
    state = push_messages(state, Enum.map(messages, &Jason.encode!/1))
    {:reply, :ok, synthesize_result(state, id, session_state_result(state))}
  end

  defp handle_fork_translation({:reply, result, state}, id),
    do: {:reply, :ok, synthesize_session_lifecycle_result(state, id, result)}

  defp handle_fork_translation({:messages_and_reply, messages, result, state}, id) do
    state = push_messages(state, Enum.map(messages, &Jason.encode!/1))
    {:reply, :ok, synthesize_session_lifecycle_result(state, id, result)}
  end

  defp handle_fork_translation({:messages_and_write, messages, _delivery, state}, _id) do
    state = push_messages(state, Enum.map(messages, &Jason.encode!/1))
    {:reply, :ok, state}
  end

  defp handle_fork_translation({:error, reason, state}, id),
    do: {:reply, :ok, synthesize_error(state, id, -32_603, to_string(reason))}

  defp synthesize_session_lifecycle_result(state, id, result) do
    synthesize_result(state, id, Map.merge(session_state_result(state), result || %{}))
  end

  defp translate_lifecycle(msg, state),
    do: state.adapter_mod.translate_outbound(msg, state.adapter_state)

  # Applies an adapter's translation of a session lifecycle request (new,
  # load, resume): adopts the adapter state, writes any control data to the
  # port, pushes any replayed messages, and synthesizes the client's reply.
  # `skip_result` builds the reply when the adapter has nothing to add.
  defp apply_lifecycle_translation(translation, id, state, error_code, skip_result) do
    case translation do
      {:ok, :skip, adapter_state} ->
        state = %{state | adapter_state: adapter_state}
        {:reply, :ok, synthesize_result(state, id, skip_result.(state))}

      {:ok, :pending, adapter_state} ->
        {:reply, :ok, %{state | adapter_state: adapter_state}}

      {:ok, data, adapter_state} ->
        state = %{state | adapter_state: adapter_state}

        case write_to_port(state, data) do
          :ok -> {:reply, :ok, state}
          {:error, reason} -> reply_translation_error(%{"id" => id}, reason, state)
        end

      {:reply, result, adapter_state} ->
        lifecycle_reply(state, adapter_state, id, [], nil, result)

      {:messages_and_reply, messages, result, adapter_state} ->
        lifecycle_reply(state, adapter_state, id, messages, nil, result)

      {:reply_and_write, result, data, adapter_state} ->
        lifecycle_reply(state, adapter_state, id, [], data, result)

      {:messages_and_reply_and_write, messages, result, data, adapter_state} ->
        lifecycle_reply(state, adapter_state, id, messages, data, result)

      {:error, reason, adapter_state} ->
        state = %{state | adapter_state: adapter_state}
        {:reply, :ok, synthesize_error(state, id, error_code, to_string(reason))}
    end
  end

  defp lifecycle_reply(state, adapter_state, id, messages, data, result) do
    state = %{state | adapter_state: adapter_state}

    case optional_write(state, data) do
      :ok ->
        state = push_encoded_messages(state, messages)

        {:reply, :ok,
         synthesize_result(state, id, Map.merge(session_state_result(state), result || %{}))}

      {:error, reason} ->
        reply_translation_error(%{"id" => id}, reason, state)
    end
  end

  defp list_sessions_result(result) when is_list(result), do: %{"sessions" => result}

  defp list_sessions_result(%{"sessions" => sessions} = result) when is_list(sessions),
    do: result

  defp list_sessions_result(%{sessions: sessions} = result) when is_list(sessions) do
    result
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Map.new()
  end

  defp list_sessions_result(_result), do: %{"sessions" => []}

  defp handle_translated_outbound({:ok, _delivery, state}, _msg), do: {:reply, :ok, state}

  defp handle_translated_outbound({:pending_and_write, :sent, state}, _msg),
    do: {:reply, :ok, state}

  defp handle_translated_outbound({:messages, messages, state}, _msg) do
    state = push_messages(state, Enum.map(messages, &Jason.encode!/1))
    {:reply, :ok, state}
  end

  defp handle_translated_outbound({:reply, result, state}, msg) do
    synthesize_translated_reply(msg, result, state)
  end

  defp handle_translated_outbound({:messages_and_reply, messages, result, state}, msg) do
    state = push_messages(state, Enum.map(messages, &Jason.encode!/1))
    synthesize_translated_reply(msg, result, state)
  end

  defp handle_translated_outbound({:reply_and_write, result, _delivery, state}, msg) do
    synthesize_translated_reply(msg, result, state)
  end

  defp handle_translated_outbound(
         {:messages_and_reply_and_write, messages, result, _delivery, state},
         msg
       ) do
    state = push_messages(state, Enum.map(messages, &Jason.encode!/1))
    synthesize_translated_reply(msg, result, state)
  end

  defp handle_translated_outbound({:messages_and_write, messages, _delivery, state}, _msg) do
    state = push_messages(state, Enum.map(messages, &Jason.encode!/1))
    {:reply, :ok, state}
  end

  defp handle_translated_outbound({:error, reason, state}, msg) do
    reply_translation_error(msg, reason, state)
  end

  defp handle_translated_outbound({:one_shot, cmd_fn, adapter_state}, _msg) do
    case start_one_shot_task(cmd_fn, adapter_state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  defp synthesize_translated_reply(%{"id" => id}, result, state) do
    {:reply, :ok, synthesize_result(state, id, result || %{})}
  end

  defp synthesize_translated_reply(_msg, _result, state), do: {:reply, :ok, state}

  defp start_one_shot_task(cmd_fn, state) do
    if map_size(state.one_shot_tasks) >= state.max_one_shot_tasks do
      {:error, :too_many_one_shot_tasks, state}
    else
      bridge_pid = self()
      token = make_ref()

      {:ok, task_pid} =
        Task.start(fn ->
          messages =
            case cmd_fn.() do
              {:ok, messages} when is_list(messages) -> messages
              {:error, _reason} -> []
              _invalid -> []
            end

          send(bridge_pid, {:one_shot_result, token, messages})
        end)

      monitor_ref = Process.monitor(task_pid)
      task = %{pid: task_pid, monitor_ref: monitor_ref}

      {:ok,
       %{
         state
         | one_shot_tasks: Map.put(state.one_shot_tasks, token, task),
           one_shot_monitors: Map.put(state.one_shot_monitors, monitor_ref, token)
       }}
    end
  end

  defp synthesize_after_translate(msg, id, state, result_fun) do
    msg
    |> translate_outbound_message(state)
    |> synthesize_after_translated(msg, id, result_fun)
  end

  defp synthesize_after_translated({:pending_and_write, :sent, state}, _msg, _id, _result_fun),
    do: {:reply, :ok, state}

  defp synthesize_after_translated(translated, msg, id, result_fun) do
    case translated_reply_parts(translated) do
      {:ok, messages, result, state} ->
        state = push_encoded_messages(state, messages)
        {:reply, :ok, synthesize_result(state, id, result || result_fun.(state))}

      {:error, reason, state} ->
        reply_translation_error(msg, reason, state)
    end
  end

  # One shape per translation, so the caller above stays a single decision.
  # A `_delivery` is a write the normalize step already performed.
  defp translated_reply_parts({:ok, _delivery, state}), do: {:ok, [], nil, state}
  defp translated_reply_parts({:reply, result, state}), do: {:ok, [], result, state}
  defp translated_reply_parts({:messages, messages, state}), do: {:ok, messages, nil, state}

  defp translated_reply_parts({:messages_and_reply, messages, result, state}),
    do: {:ok, messages, result, state}

  defp translated_reply_parts({:reply_and_write, result, _delivery, state}),
    do: {:ok, [], result, state}

  defp translated_reply_parts({:messages_and_write, messages, _delivery, state}),
    do: {:ok, messages, nil, state}

  defp translated_reply_parts(
         {:messages_and_reply_and_write, messages, result, _delivery, state}
       ),
       do: {:ok, messages, result, state}

  defp translated_reply_parts({:error, reason, state}), do: {:error, reason, state}

  defp push_encoded_messages(state, []), do: state

  defp push_encoded_messages(state, messages),
    do: push_messages(state, Enum.map(messages, &Jason.encode!/1))

  defp reply_translation_error(%{"id" => id}, reason, state) do
    {:reply, :ok, synthesize_error(state, id, -32_603, to_string(reason))}
  end

  defp reply_translation_error(_msg, reason, state) do
    {:reply, {:error, reason}, state}
  end

  defp translate_outbound_message(msg, state) do
    case state.adapter_mod.translate_outbound(msg, state.adapter_state) do
      {:pending_and_write, data, adapter_state} ->
        write_pending_translation(msg, data, adapter_state, state)

      translated ->
        normalize_translated_outbound(translated, state)
    end
  end

  defp write_pending_translation(msg, data, adapter_state, state) do
    state = %{state | adapter_state: adapter_state}

    case write_to_port(state, data) do
      :ok ->
        {:pending_and_write, :sent, state}

      {:error, reason} ->
        adapter_state =
          if function_exported?(state.adapter_mod, :outbound_write_failed, 3),
            do: state.adapter_mod.outbound_write_failed(msg, reason, adapter_state),
            else: adapter_state

        {:error, reason, %{state | adapter_state: adapter_state}}
    end
  end

  defp normalize_translated_outbound({:ok, :skip, adapter_state}, state),
    do: {:ok, :skip, %{state | adapter_state: adapter_state}}

  defp normalize_translated_outbound({:ok, :pending, adapter_state}, state),
    do: {:ok, :pending, %{state | adapter_state: adapter_state}}

  defp normalize_translated_outbound({:ok, data, adapter_state}, state) do
    state = %{state | adapter_state: adapter_state}
    write_translation_to_port(state, {:ok, :sent}, data)
  end

  defp normalize_translated_outbound({:reply, result, adapter_state}, state),
    do: {:reply, result, %{state | adapter_state: adapter_state}}

  defp normalize_translated_outbound({:messages, messages, adapter_state}, state),
    do: {:messages, messages, %{state | adapter_state: adapter_state}}

  defp normalize_translated_outbound(
         {:messages_and_reply, messages, result, adapter_state},
         state
       ),
       do: {:messages_and_reply, messages, result, %{state | adapter_state: adapter_state}}

  defp normalize_translated_outbound({:reply_and_write, result, data, adapter_state}, state) do
    state = %{state | adapter_state: adapter_state}
    write_translation_to_port(state, {:reply_and_write, result, :sent}, data)
  end

  defp normalize_translated_outbound(
         {:messages_and_reply_and_write, messages, result, data, adapter_state},
         state
       ) do
    state = %{state | adapter_state: adapter_state}

    write_translation_to_port(
      state,
      {:messages_and_reply_and_write, messages, result, :sent},
      data
    )
  end

  defp normalize_translated_outbound(
         {:messages_and_write, messages, data, adapter_state},
         state
       ) do
    state = %{state | adapter_state: adapter_state}
    write_translation_to_port(state, {:messages_and_write, messages, :sent}, data)
  end

  defp normalize_translated_outbound({:error, reason, adapter_state}, state),
    do: {:error, reason, %{state | adapter_state: adapter_state}}

  defp normalize_translated_outbound({:one_shot, cmd_fn, adapter_state}, state),
    do: {:one_shot, cmd_fn, %{state | adapter_state: adapter_state}}

  defp write_translation_to_port(state, success, data) do
    case write_to_port(state, data) do
      :ok -> translated_write_success(success, state)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp translated_write_success({:ok, :sent}, state), do: {:ok, :sent, state}

  defp translated_write_success({:reply_and_write, result, :sent}, state),
    do: {:reply_and_write, result, :sent, state}

  defp translated_write_success({:messages_and_reply_and_write, messages, result, :sent}, state),
    do: {:messages_and_reply_and_write, messages, result, :sent, state}

  defp translated_write_success({:messages_and_write, messages, :sent}, state),
    do: {:messages_and_write, messages, :sent, state}

  defp write_to_port(%{port: nil}, _data), do: {:error, :no_port}

  defp write_to_port(%{port: port}, data) do
    PortRunner.command(port, data)
  end

  defp optional_write(_state, nil), do: :ok
  defp optional_write(state, data), do: write_to_port(state, data)

  defp translate_port_line(state, line) do
    case state.adapter_mod.translate_inbound(line, state.adapter_state) do
      {:messages, messages, new_adapter_state} ->
        state = %{state | adapter_state: new_adapter_state}
        push_native_messages(state, messages, line)

      {:messages_and_write, messages, write_data, new_adapter_state} ->
        state = %{state | adapter_state: new_adapter_state}
        state = push_native_messages(state, messages, line)
        write_native_reply(state, write_data)

      {:skip_and_write, write_data, new_adapter_state} ->
        state = %{state | adapter_state: new_adapter_state}
        write_native_reply(state, write_data)

      {:partial, new_adapter_state} ->
        %{state | adapter_state: new_adapter_state}

      {:skip, new_adapter_state} ->
        %{state | adapter_state: new_adapter_state}
    end
  end

  defp write_native_reply(%{status: :closed} = state, _data), do: state

  defp write_native_reply(state, data) do
    case write_to_port(state, data) do
      :ok -> state
      {:error, reason} -> overflow_close(state, {:native_write_failed, reason})
    end
  end

  defp flush_buffer(%{buffer: ""} = state), do: state

  defp flush_buffer(%{buffer: buffer} = state) do
    state = %{state | buffer: ""}

    case state.adapter_mod.translate_inbound(buffer, state.adapter_state) do
      {:messages, messages, new_adapter_state} ->
        state = %{state | adapter_state: new_adapter_state}
        push_native_messages(state, messages, buffer)

      _ ->
        state
    end
  end

  # With `native_events: :summary` or `:raw`, every ACP message an adapter
  # derives from one native line is tagged under `_meta.ex_mcp.native` with the
  # adapter name and a per-bridge sequence number, plus the decoded native
  # event for `:raw`. The default is `:off` so the 1.x wire shape is unchanged
  # unless a consumer opts in. Messages the adapter produces outside
  # `translate_inbound/2` (post_connect, adapter-managed processes, synthesized
  # responses) are not derived from a native line and are left untouched.
  defp push_native_messages(state, [], _line), do: state

  defp push_native_messages(%{native_events: :off} = state, messages, _line),
    do: push_messages(state, Enum.map(messages, &Jason.encode!/1))

  defp push_native_messages(state, messages, line) do
    sequence = state.native_sequence + 1

    native =
      %{"adapter" => state.adapter_name, "sequence" => sequence}
      |> maybe_put_native_event(state.native_events, line)

    encoded = Enum.map(messages, &(&1 |> put_native_meta(native) |> Jason.encode!()))
    push_messages(%{state | native_sequence: sequence}, encoded)
  end

  defp maybe_put_native_event(native, :raw, line) do
    case Jason.decode(line) do
      {:ok, event} -> Map.put(native, "event", event)
      {:error, _} -> Map.put(native, "raw", line)
    end
  end

  defp maybe_put_native_event(native, _mode, _line), do: native

  defp put_native_meta(
         %{"method" => "session/update", "params" => %{"update" => update} = params} = message,
         native
       )
       when is_map(update) do
    update = Meta.put_ex_mcp(update, %{"native" => native})
    %{message | "params" => %{params | "update" => update}}
  end

  defp put_native_meta(%{"method" => _, "params" => params} = message, native)
       when is_map(params),
       do: %{message | "params" => Meta.put_ex_mcp(params, %{"native" => native})}

  defp put_native_meta(%{"result" => result} = message, native) when is_map(result),
    do: %{message | "result" => Meta.put_ex_mcp(result, %{"native" => native})}

  defp put_native_meta(message, _native), do: message

  defp native_events_option(opts) do
    case Keyword.get(opts, :native_events, :off) do
      mode when mode in [:off, :summary, :raw] ->
        mode

      other ->
        raise ArgumentError,
              "native_events must be :off, :summary, or :raw, got: #{inspect(other)}"
    end
  end

  defp push_message(state, message) do
    cond do
      byte_size(message) > state.max_buffer_bytes ->
        overflow_close(state, :frame_too_large)

      state.status == :closed ->
        state

      true ->
        deliver_or_enqueue(state, message)
    end
  end

  defp deliver_or_enqueue(state, message) do
    case :queue.out(state.waiters) do
      {{:value, %{from: from, timer_ref: timer_ref} = waiter}, rest} ->
        cancel_timer(timer_ref)

        if caller_alive?(from) and not waiter_expired?(waiter) do
          GenServer.reply(from, {:ok, message})
          %{state | waiters: rest}
        else
          deliver_or_enqueue(%{state | waiters: rest}, message)
        end

      {{:value, waiter}, rest} ->
        if caller_alive?(waiter) do
          GenServer.reply(waiter, {:ok, message})
          %{state | waiters: rest}
        else
          deliver_or_enqueue(%{state | waiters: rest}, message)
        end

      {:empty, _} ->
        if :queue.len(state.outbox) >= state.max_outbox_messages or
             state.outbox_bytes + byte_size(message) > state.max_outbox_bytes do
          overflow_close(state, :outbox_overflow)
        else
          %{
            state
            | outbox: :queue.in({message, System.monotonic_time(:millisecond)}, state.outbox),
              outbox_bytes: state.outbox_bytes + byte_size(message)
          }
        end
    end
  end

  defp push_messages(state, messages) do
    Enum.reduce(messages, state, &push_message(&2, &1))
  end

  defp reply_error_to_waiters(state, reason) do
    state.waiters
    |> :queue.to_list()
    |> Enum.each(fn
      %{from: from, timer_ref: timer_ref} ->
        cancel_timer(timer_ref)
        GenServer.reply(from, {:error, reason})

      from ->
        GenServer.reply(from, {:error, reason})
    end)

    %{state | waiters: :queue.new()}
  end

  defp prune_dead_waiters(waiters) do
    waiters
    |> :queue.to_list()
    |> Enum.filter(fn
      %{from: from, timer_ref: timer_ref} = waiter ->
        keep? = caller_alive?(from) and not waiter_expired?(waiter)
        if not keep?, do: cancel_timer(timer_ref)
        keep?

      from ->
        caller_alive?(from)
    end)
    |> :queue.from_list()
  end

  defp delete_waiter(waiters, token) do
    waiters
    |> :queue.to_list()
    |> Enum.reject(fn
      %{token: ^token} -> true
      _waiter -> false
    end)
    |> :queue.from_list()
  end

  defp schedule_waiter_timeout(_token, :infinity), do: nil

  defp schedule_waiter_timeout(token, timeout) when is_integer(timeout) and timeout > 0,
    do: Process.send_after(self(), {:waiter_timeout, token}, timeout)

  defp schedule_waiter_timeout(token, _timeout),
    do: Process.send_after(self(), {:waiter_timeout, token}, 0)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer_ref), do: Process.cancel_timer(timer_ref, async: true, info: false)

  defp deadline_remaining(:infinity), do: :infinity
  defp deadline_remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  defp buffered_before?(queue, deadline) do
    case :queue.peek(queue) do
      {:value, {_message, received_at}} -> received_at <= deadline
      :empty -> false
    end
  end

  defp waiter_expired?(%{deadline: :infinity}), do: false

  defp waiter_expired?(%{deadline: deadline}) when is_integer(deadline),
    do: System.monotonic_time(:millisecond) >= deadline

  defp waiter_expired?(_waiter), do: false

  defp caller_alive?({pid, _tag}) when is_pid(pid), do: Process.alive?(pid)
  defp caller_alive?(_from), do: false

  defp overflow_close(state, reason) do
    state
    |> do_close()
    |> Map.merge(%{buffer: "", outbox: :queue.new(), outbox_bytes: 0, status: :closed})
    |> reply_error_to_waiters(reason)
  end

  defp handle_adapter_message(msg, state) do
    if function_exported?(state.adapter_mod, :handle_adapter_message, 2) do
      receipt = subprocess_receipt(msg, state)

      state =
        case state.adapter_mod.handle_adapter_message(msg, state.adapter_state) do
          {:messages, messages, adapter_state} ->
            state
            |> Map.put(:adapter_state, adapter_state)
            |> push_messages(Enum.map(messages, &Jason.encode!/1))

          {:partial, adapter_state} ->
            %{state | adapter_state: adapter_state}

          {:skip, adapter_state} ->
            %{state | adapter_state: adapter_state}
        end

      acknowledge_frame(state, receipt)
    else
      state
    end
  end

  defp subprocess_receipt(msg, state) do
    if function_exported?(state.adapter_mod, :subprocess_receipt, 2),
      do: state.adapter_mod.subprocess_receipt(msg, state.adapter_state),
      else: nil
  end

  defp acknowledge_frame(%{status: :closed} = state, _receipt), do: state
  defp acknowledge_frame(state, nil), do: state

  defp acknowledge_frame(state, {handle, token}) do
    case PortRunner.ack(handle, token) do
      :ok -> state
      # A managed callback may intentionally close or replace this generation
      # while admitting its final messages. There is no more credit to grant.
      {:error, :closed} -> state
      {:error, _reason} -> overflow_close(state, :port_closed)
    end
  end

  defp close_stream(state, :frame_too_large, _remainder),
    do: overflow_close(state, :frame_too_large)

  defp close_stream(state, reason, remainder) do
    state = %{state | buffer: remainder} |> flush_buffer()

    error =
      if match?({:exit_status, _}, reason), do: :port_exited, else: {:subprocess_closed, reason}

    state = %{state | cleanup_result: cleanup_result(reason, state.cleanup_result)}
    state |> clear_port() |> reply_error_to_waiters(error)
  end

  defp cleanup_result({:cleanup_failed, _reason, result}, _previous), do: result
  defp cleanup_result(_reason, previous), do: previous

  defp clear_port(state) do
    if state.port_monitor, do: Process.demonitor(state.port_monitor, [:flush])
    %{state | port: nil, port_monitor: nil, status: :closed}
  end

  defp do_close(%{port: nil} = state) do
    state
    |> shutdown_adapter()
    |> reply_error_to_waiters(:closed)
    |> Map.put(:status, :closed)
  end

  defp do_close(%{port: port} = state) do
    result = PortRunner.close(port)
    state = if result == :ok, do: state, else: %{state | cleanup_result: result}

    state =
      state
      |> shutdown_adapter()
      |> reply_error_to_waiters(:closed)

    clear_port(state)
  end

  defp shutdown_adapter(state) do
    Enum.each(state.one_shot_tasks, fn {_token, %{pid: pid}} ->
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end)

    state = %{state | one_shot_tasks: %{}, one_shot_monitors: %{}}

    if function_exported?(state.adapter_mod, :shutdown, 1) do
      case state.adapter_mod.shutdown(state.adapter_state) do
        {:ok, adapter_state} ->
          %{state | adapter_state: adapter_state}

        {:error, reason, adapter_state} ->
          %{state | adapter_state: adapter_state, cleanup_result: {:error, reason}}

        adapter_state ->
          %{state | adapter_state: adapter_state}
      end
    else
      state
    end
  end
end
