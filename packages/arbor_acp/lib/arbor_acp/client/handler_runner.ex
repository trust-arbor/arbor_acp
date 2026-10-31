defmodule Arbor.ACP.Client.HandlerRunner do
  @moduledoc false

  use GenServer

  alias Arbor.RPC.LogSummary

  require Logger

  defstruct [
    :handler_mod,
    :handler_state,
    :owner,
    :mcp_gate,
    mcp_workers: %{},
    async_workers: %{}
  ]

  def start_link(handler_mod, handler_opts, owner, scope \\ nil) do
    GenServer.start_link(__MODULE__, {handler_mod, handler_opts, owner, scope})
  end

  # rc.6 compatibility: unbounded enqueue used Client defaults after security harden.
  @default_max_update_queue 32
  @default_max_update_queue_bytes 8_388_608

  @doc false
  def session_update(pid, session_id, update) do
    _ =
      session_update(
        pid,
        session_id,
        update,
        @default_max_update_queue,
        @default_max_update_queue_bytes
      )

    :ok
  end

  def session_update(pid, session_id, update, max_queue, max_queue_bytes) do
    session_update(pid, session_id, update, max_queue, max_queue_bytes, nil)
  end

  # `message` is the decoded JSON-RPC envelope, passed only when the handler
  # exports the context-aware callback (the Client checks that). It embeds the
  # update, so its size is the retained size when present.
  def session_update(pid, session_id, update, max_queue, max_queue_bytes, message) do
    incoming_bytes = update_size(update, message)

    if update_mailbox_below_limits?(pid, max_queue, max_queue_bytes, incoming_bytes) do
      GenServer.cast(pid, {:session_update, session_id, update, message})
      :ok
    else
      :dropped
    end
  end

  defp update_mailbox_below_limits?(pid, count_limit, byte_limit, incoming_bytes) do
    with {:message_queue_len, length} when length < count_limit <-
           Process.info(pid, :message_queue_len),
         {:messages, messages} when length(messages) < count_limit <-
           Process.info(pid, :messages) do
      incoming_bytes <= byte_limit - queued_update_bytes(messages, byte_limit)
    else
      _full_or_closed -> false
    end
  end

  defp queued_update_bytes(messages, limit) do
    Enum.reduce_while(messages, 0, fn message, total ->
      total = total + queued_update_size(message)
      if total >= limit, do: {:halt, total}, else: {:cont, total}
    end)
  end

  defp queued_update_size({:"$gen_cast", {:session_update, _session_id, update, message}}),
    do: update_size(update, message)

  defp queued_update_size({:"$gen_cast", {:extension_notification, _method, _params}} = message),
    do: :erlang.external_size(message)

  defp queued_update_size(_message), do: 0

  defp update_size(update, nil), do: :erlang.external_size(update)
  defp update_size(_update, message), do: :erlang.external_size(message)

  # The admission bit is visible while a request is still queued behind a
  # synchronous callback. Cancellation must not wait for that mailbox.
  def new_request_ref do
    gate = :atomics.new(1, signed: false)
    :atomics.put(gate, 1, 1)
    {:acp_handler_request, make_ref(), gate}
  end

  def request_gate({:acp_handler_request, _ref, gate}), do: gate
  def request_gate(_ref), do: nil

  defp request_open?(ref) do
    case request_gate(ref) do
      nil -> true
      gate -> :atomics.get(gate, 1) == 1
    end
  end

  def extension_request(pid, ref, method, params),
    do: GenServer.cast(pid, {:extension_request, ref, method, params})

  def extension_notification(pid, method, params, max_queue, max_bytes) do
    if update_mailbox_below_limits?(
         pid,
         max_queue,
         max_bytes,
         :erlang.external_size({:"$gen_cast", {:extension_notification, method, params}})
       ) do
      GenServer.cast(pid, {:extension_notification, method, params})
      :ok
    else
      :dropped
    end
  end

  def permission_request(pid, ref, session_id, tool_call, options, message) do
    GenServer.cast(pid, {:permission_request, ref, session_id, tool_call, options, message})
  end

  def file_read(pid, ref, session_id, path, opts) do
    GenServer.cast(pid, {:file_read, ref, session_id, path, opts})
  end

  def file_write(pid, ref, session_id, path, content) do
    GenServer.cast(pid, {:file_write, ref, session_id, path, content})
  end

  def terminal_request(pid, ref, method, params, id) do
    GenServer.cast(pid, {:terminal_request, ref, method, params, id})
  end

  def elicitation_request(pid, ref, mode, params) do
    GenServer.cast(pid, {:elicitation_request, ref, mode, params})
  end

  def elicitation_complete(pid, elicitation_id) do
    GenServer.cast(pid, {:elicitation_complete, elicitation_id})
  end

  def mcp_request(pid, ref, provider, context, params) do
    GenServer.cast(pid, {:mcp_request, ref, provider, context, params})
  end

  # Closes the MCP gate without waiting behind casts already in the mailbox.
  # A provider callback that has not entered `run_mcp/5` does not start.
  @doc false
  def refuse_mcp(pid) when is_pid(pid) do
    case mcp_gate(pid) do
      nil -> :ok
      gate -> :atomics.put(gate, 1, 0)
    end
  end

  defp mcp_gate(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        case List.keyfind(dict, :acp_mcp_gate, 0) do
          {:acp_mcp_gate, gate} -> gate
          _missing -> nil
        end

      _dead ->
        nil
    end
  end

  # Each of these has a legacy arity and a context-aware arity that also takes
  # the decoded JSON-RPC message. Both are optional on the behaviour so a
  # handler can implement just one, but it must export at least one of each
  # or updates and permission requests would fail at first dispatch.
  @callback_pairs [handle_session_update: [3, 4], handle_permission_request: [4, 5]]

  @impl true
  def init({handler_mod, handler_opts, owner, scope}) do
    Process.flag(:trap_exit, true)

    case Arbor.ACP.Client.ConnectionScope.register(scope, :handler) do
      :ok -> :ok
      {:error, reason} -> exit(reason)
    end

    case missing_callback(handler_mod) do
      nil -> init_handler(handler_mod, handler_opts, owner)
      callback -> {:stop, {:handler_init_failed, {:missing_callback, callback}}}
    end
  end

  defp init_handler(handler_mod, handler_opts, owner) do
    case safe_call(fn -> handler_mod.init(handler_opts) end) do
      {:ok, {:ok, handler_state}} ->
        gate = :atomics.new(1, signed: false)
        :atomics.put(gate, 1, 1)
        Process.put(:acp_mcp_gate, gate)

        {:ok,
         %__MODULE__{
           handler_mod: handler_mod,
           handler_state: handler_state,
           owner: owner,
           mcp_gate: gate
         }}

      {:ok, {:error, reason}} ->
        {:stop, {:handler_init_failed, reason}}

      {:ok, other} ->
        {:stop, {:handler_init_failed, {:invalid_return, other}}}

      {:error, reason} ->
        {:stop, {:handler_init_failed, reason}}
    end
  end

  defp missing_callback(handler_mod) do
    Code.ensure_loaded(handler_mod)

    Enum.find_value(@callback_pairs, fn {callback, arities} ->
      if not Enum.any?(arities, &function_exported?(handler_mod, callback, &1)), do: callback
    end)
  end

  @impl true
  def handle_cast(message, state) do
    if tuple_size(message) > 1 and not request_open?(elem(message, 1)) do
      {:noreply, state}
    else
      cast_message(message, state)
    end
  end

  defp cast_message({:session_update, session_id, update, message}, state) do
    case safe_call(fn ->
           call_with_context(state, :handle_session_update, [session_id, update], message)
         end) do
      {:ok, {:ok, handler_state}} ->
        {:noreply, %{state | handler_state: handler_state}}

      {:ok, other} ->
        Logger.warning("ACP handler returned invalid session update result",
          return_shape: return_shape(other)
        )

        {:noreply, state}

      {:error, reason} ->
        Logger.warning("ACP handler session update failed", error_class: error_class(reason))
        {:noreply, state}
    end
  end

  defp cast_message({:extension_request, ref, method, params}, state) do
    {result, state} =
      case safe_call(fn ->
             state.handler_mod.handle_extension_request(method, params, state.handler_state)
           end) do
        {:ok, {:async, work, handler_state}} when is_function(work, 0) ->
          {{:async, work}, %{state | handler_state: handler_state}}

        {:ok, {:ok, result, handler_state}} ->
          {{:ok, result}, %{state | handler_state: handler_state}}

        {:ok, {:error, error, handler_state}} ->
          {{:error, error}, %{state | handler_state: handler_state}}

        _ ->
          {{:error, %{"code" => -32_603, "message" => "Extension handler failed"}}, state}
      end

    reply_or_start_worker(state, ref, :extension, result)
  end

  defp cast_message({:extension_notification, method, params}, state) do
    state =
      case safe_call(fn ->
             state.handler_mod.handle_extension_notification(method, params, state.handler_state)
           end) do
        {:ok, {:ok, handler_state}} -> %{state | handler_state: handler_state}
        _ -> state
      end

    {:noreply, state}
  end

  defp cast_message({:permission_request, ref, session_id, tool_call, options, message}, state) do
    {result, state} =
      case safe_call(fn ->
             call_with_context(
               state,
               :handle_permission_request,
               [session_id, tool_call, options],
               message
             )
           end) do
        {:ok, {:async, work, handler_state}} when is_function(work, 0) ->
          {{:async, work}, %{state | handler_state: handler_state}}

        {:ok, {:ok, outcome, handler_state}} ->
          {{:ok, outcome}, %{state | handler_state: handler_state}}

        {:ok, {:error, reason, handler_state}} ->
          {{:error, reason}, %{state | handler_state: handler_state}}

        {:ok, other} ->
          {{:error, {:invalid_return, other}}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end

    reply_or_start_worker(state, ref, :permission, result)
  end

  defp cast_message({:file_read, ref, session_id, path, opts}, state) do
    {result, state} =
      case safe_call(fn ->
             state.handler_mod.handle_file_read(session_id, path, opts, state.handler_state)
           end) do
        {:ok, {:async, work, handler_state}} when is_function(work, 0) ->
          {{:async, work}, %{state | handler_state: handler_state}}

        {:ok, {:ok, content, handler_state}} ->
          {{:ok, content}, %{state | handler_state: handler_state}}

        {:ok, {:error, reason, handler_state}} ->
          {{:error, reason}, %{state | handler_state: handler_state}}

        {:ok, other} ->
          {{:error, {:invalid_return, other}}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end

    reply_or_start_worker(state, ref, :file_read, result)
  end

  defp cast_message({:file_write, ref, session_id, path, content}, state) do
    {result, state} =
      case safe_call(fn ->
             state.handler_mod.handle_file_write(session_id, path, content, state.handler_state)
           end) do
        {:ok, {:async, work, handler_state}} when is_function(work, 0) ->
          {{:async, work}, %{state | handler_state: handler_state}}

        {:ok, {:ok, handler_state}} ->
          {:ok, %{state | handler_state: handler_state}}

        {:ok, {:error, reason, handler_state}} ->
          {{:error, reason}, %{state | handler_state: handler_state}}

        {:ok, other} ->
          {{:error, {:invalid_return, other}}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end

    reply_or_start_worker(state, ref, :file_write, result)
  end

  defp cast_message({:terminal_request, ref, method, params, id}, state) do
    {result, state} =
      case safe_call(fn ->
             state.handler_mod.handle_terminal_request(method, params, id, state.handler_state)
           end) do
        {:ok, {:async, work, handler_state}} when is_function(work, 0) ->
          {{:async, work}, %{state | handler_state: handler_state}}

        {:ok, {:ok, response, handler_state}} ->
          {{:ok, response}, %{state | handler_state: handler_state}}

        {:ok, {:error, reason, handler_state}} ->
          {{:error, reason}, %{state | handler_state: handler_state}}

        {:ok, other} ->
          {{:error, {:invalid_return, other}}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end

    reply_or_start_worker(state, ref, :terminal, result)
  end

  defp cast_message({:elicitation_request, ref, mode, params}, state) do
    callback = if mode == "form", do: :handle_form_elicitation, else: :handle_url_elicitation

    {result, state} =
      case safe_call(fn -> apply(state.handler_mod, callback, [params, state.handler_state]) end) do
        {:ok, {:async, work, handler_state}} when is_function(work, 0) ->
          {{:async, work}, %{state | handler_state: handler_state}}

        {:ok, {:ok, response, handler_state}} ->
          {{:ok, response}, %{state | handler_state: handler_state}}

        {:ok, {:error, reason, handler_state}} ->
          {{:error, reason}, %{state | handler_state: handler_state}}

        {:ok, other} ->
          {{:error, {:invalid_return, other}}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end

    reply_or_start_worker(state, ref, :elicitation, result)
  end

  defp cast_message({:elicitation_complete, elicitation_id}, state) do
    state =
      case safe_call(fn ->
             state.handler_mod.handle_elicitation_complete(elicitation_id, state.handler_state)
           end) do
        {:ok, {:ok, handler_state}} -> %{state | handler_state: handler_state}
        _invalid_or_failed -> state
      end

    {:noreply, state}
  end

  defp cast_message({:mcp_request, ref, provider, context, params}, state) do
    start_mcp_worker(state, ref, provider, context, params)
  end

  @impl true
  def handle_info({:mcp_worker_done, ref, outcome, new_state}, state) do
    case Map.pop(state.mcp_workers, ref) do
      {nil, _workers} ->
        {:noreply, state}

      {%{monitor: monitor}, workers} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | mcp_workers: workers}

        if outcome == :skipped do
          {:noreply, state}
        else
          _ = apply_mcp_state(new_state)
          send(state.owner, {:acp_handler_result, ref, {:mcp, outcome}})
          {:noreply, state}
        end
    end
  end

  def handle_info({:handler_worker_done, ref, outcome}, state) do
    case Map.pop(state.async_workers, ref) do
      {nil, _workers} ->
        {:noreply, state}

      {%{monitor: monitor, kind: kind}, workers} ->
        Process.demonitor(monitor, [:flush])

        if outcome != :skipped and request_open?(ref) and mcp_open?(state.mcp_gate),
          do: send(state.owner, {:acp_handler_result, ref, {kind, outcome}})

        {:noreply, %{state | async_workers: workers}}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case pop_mcp_worker(state, monitor) do
      {nil, state} ->
        case Enum.find(state.async_workers, fn {_ref, worker} -> worker.monitor == monitor end) do
          nil ->
            {:noreply, state}

          {ref, worker} ->
            if request_open?(ref),
              do:
                send(
                  state.owner,
                  {:acp_handler_result, ref, {worker.kind, {:error, {:exit, reason}}}}
                )

            {:noreply, %{state | async_workers: Map.delete(state.async_workers, ref)}}
        end

      {{ref, _worker}, state} ->
        send(state.owner, {:acp_handler_result, ref, {:mcp, {:error, {:exit, reason}}}})
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Enum.each(Map.merge(state.mcp_workers, state.async_workers), fn {_ref, %{pid: pid}} ->
      Process.exit(pid, :kill)
    end)

    if function_exported?(state.handler_mod, :terminate, 2) do
      _ = safe_call(fn -> state.handler_mod.terminate(reason, state.handler_state) end)
    end

    :ok
  end

  defp reply_or_start_worker(state, ref, kind, {:async, work}) do
    runner = self()
    owner = state.owner
    gate = state.mcp_gate

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          admitted =
            if request_gate(ref) do
              try do
                GenServer.call(owner, {:handler_worker_admit, ref, self()}, :infinity)
              catch
                :exit, _ -> false
              end
            else
              {:ok, :infinity}
            end

          if request_open?(ref) and mcp_open?(gate) and admission_current?(admitted) do
            outcome = normalize_work_result(kind, safe_call(work))
            send(runner, {:handler_worker_done, ref, outcome})
          else
            # The Client's timeout/cancellation path owns settlement. Retire
            # normally without converting this skip into a worker failure.
            send(runner, {:handler_worker_done, ref, :skipped})
          end
        end,
        [:link, :monitor]
      )

    worker = %{pid: pid, monitor: monitor, kind: kind}
    {:noreply, %{state | async_workers: Map.put(state.async_workers, ref, worker)}}
  end

  defp reply_or_start_worker(state, ref, kind, result) do
    send(state.owner, {:acp_handler_result, ref, {kind, result}})
    {:noreply, state}
  end

  defp normalize_work_result(:file_write, {:ok, :ok}), do: :ok

  defp normalize_work_result(kind, {:ok, {:ok, value}}) when kind != :file_write,
    do: {:ok, value}

  defp normalize_work_result(_kind, {:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_work_result(_kind, {:error, reason}), do: {:error, reason}
  defp normalize_work_result(_kind, {:ok, other}), do: {:error, {:invalid_return, other}}

  # The Client passes `message` only when the handler exports the context
  # variant, so its presence selects the arity.
  defp call_with_context(state, callback, args, nil),
    do: apply(state.handler_mod, callback, args ++ [state.handler_state])

  defp call_with_context(state, callback, args, message),
    do: apply(state.handler_mod, callback, args ++ [message, state.handler_state])

  # Unlinked so a stalled or crashed provider cannot take the runner down.
  # The client kills the worker when its handler timeout, a cancel, or a
  # disconnect fires. `:handler` and module callbacks run concurrently and
  # do not change handler state. A callback that has not entered after
  # `refuse_mcp/1` does not start. One that is still queued also checks, right
  # before it enters, that its session is open and its request is still
  # pending. In-flight workers stay bounded by the client's pending-request cap.
  defp start_mcp_worker(state, ref, provider, context, params) do
    if mcp_open?(state.mcp_gate) do
      launch_mcp_worker(state, ref, provider, context, params)
    else
      send(state.owner, {:acp_handler_result, ref, {:mcp, {:error, :disconnected}}})
      {:noreply, state}
    end
  end

  defp launch_mcp_worker(state, ref, provider, context, params) do
    runner = self()
    owner = state.owner
    handler_mod = state.handler_mod
    snapshot = state.handler_state
    gate = state.mcp_gate

    {:ok, pid} =
      Task.start(fn ->
        run_admitted_mcp(
          runner,
          owner,
          ref,
          gate,
          provider,
          context,
          params,
          handler_mod,
          snapshot
        )
      end)

    monitor = Process.monitor(pid)

    {:noreply,
     %{state | mcp_workers: Map.put(state.mcp_workers, ref, %{pid: pid, monitor: monitor})}}
  end

  # A queued callback can sit behind another handler callback. The client
  # answers that request when the session closes, before this task has a
  # worker pid. The session and the pending request are checked again
  # immediately before the provider runs. `:skipped` settles the task
  # without a second answer when that request was already answered.
  defp run_admitted_mcp(
         runner,
         owner,
         ref,
         gate,
         provider,
         context,
         params,
         handler_mod,
         snapshot
       ) do
    cond do
      not mcp_open?(gate) ->
        send(runner, {:mcp_worker_done, ref, {:error, :disconnected}, :unchanged})

      not provider_admitted?(owner, ref, context.session_id) ->
        send(runner, {:mcp_worker_done, ref, :skipped, :unchanged})

      true ->
        send(owner, {:acp_mcp_worker, ref, self()})

        cond do
          not mcp_open?(gate) ->
            send(runner, {:mcp_worker_done, ref, {:error, :disconnected}, :unchanged})

          not provider_admitted?(owner, ref, context.session_id) ->
            send(runner, {:mcp_worker_done, ref, :skipped, :unchanged})

          true ->
            {outcome, new_state} = run_mcp(provider, context, params, handler_mod, snapshot)
            send(runner, {:mcp_worker_done, ref, outcome, new_state})
        end
    end
  end

  defp provider_admitted?(owner, ref, session_id) do
    admission = GenServer.call(owner, {:mcp_provider_admitted, ref, session_id}, :infinity)
    admission_current?(admission)
  catch
    :exit, _reason -> false
  end

  # Admission can be delayed in transit or after the worker is rescheduled.
  # Check the owning deadline locally immediately before entering user work.
  defp admission_current?({:ok, :infinity}), do: true

  defp admission_current?({:ok, deadline}) when is_integer(deadline),
    do: deadline > System.monotonic_time(:millisecond)

  defp admission_current?(_denied), do: false

  # Handler state is never replaced from an MCP callback. `:unchanged` is the
  # only accepted outcome so a returned state cannot be stored by mistake.
  defp apply_mcp_state(:unchanged), do: :ok

  defp mcp_open?(gate), do: :atomics.get(gate, 1) == 1

  defp pop_mcp_worker(state, monitor) do
    case Enum.find(state.mcp_workers, fn {_ref, worker} -> worker.monitor == monitor end) do
      nil ->
        {nil, state}

      {ref, worker} ->
        {{ref, worker}, %{state | mcp_workers: Map.delete(state.mcp_workers, ref)}}
    end
  end

  defp run_mcp(:handler, context, params, handler_mod, handler_state) do
    case safe_call(fn ->
           handler_mod.handle_mcp_request(context.session_id, params, context, handler_state)
         end) do
      {:ok, {:ok, result, new_state}} ->
        discard_changed_state(handler_state, new_state, context)
        {{:ok, result}, :unchanged}

      {:ok, {:mcp_error, error, new_state}} ->
        discard_changed_state(handler_state, new_state, context)
        {{:mcp_error, error}, :unchanged}

      {:ok, {:error, reason, new_state}} ->
        discard_changed_state(handler_state, new_state, context)
        {{:error, reason}, :unchanged}

      {:ok, other} ->
        {{:error, {:invalid_return, other}}, :unchanged}

      {:error, reason} ->
        {{:error, reason}, :unchanged}
    end
  end

  defp run_mcp(module, context, params, _handler_mod, _handler_state) when is_atom(module) do
    case safe_call(fn -> module.handle_mcp_request(context, params) end) do
      {:ok, {:ok, result}} -> {{:ok, result}, :unchanged}
      {:ok, {:mcp_error, error}} -> {{:mcp_error, error}, :unchanged}
      {:ok, {:error, reason}} -> {{:error, reason}, :unchanged}
      {:ok, other} -> {{:error, {:invalid_return, other}}, :unchanged}
      {:error, reason} -> {{:error, reason}, :unchanged}
    end
  end

  defp discard_changed_state(handler_state, handler_state, _context), do: :ok

  defp discard_changed_state(_handler_state, _new_state, context) do
    session_id_hash = LogSummary.fingerprint(context.session_id)

    Logger.error(
      "ACP handler MCP callback returned a changed state and the change was discarded",
      session_id_hash: session_id_hash
    )

    :telemetry.execute(
      [:arbor_acp, :mcp, :handler, :state_discarded],
      %{count: 1},
      %{session_id_hash: session_id_hash}
    )
  end

  defp safe_call(fun) do
    {:ok, fun.()}
  catch
    kind, reason ->
      {:error, {kind, reason, __STACKTRACE__}}
  end

  defp return_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp return_shape(value) when is_map(value), do: :map
  defp return_shape(value) when is_list(value), do: :list
  defp return_shape(value) when is_atom(value), do: :atom
  defp return_shape(_value), do: :other

  defp error_class({kind, reason, _stack}) when kind in [:error, :exit, :throw],
    do: {kind, exception_module(reason)}

  defp exception_module(%{__struct__: module}) when is_atom(module), do: module
  defp exception_module(_reason), do: :non_exception
end
