defmodule Arbor.ACP.Client.ConnectionScope do
  @moduledoc false
  use GenServer

  alias Arbor.ACP.Client
  alias Arbor.ACP.Transport.Stdio

  def run(client_opts, opts, callback) when is_function(callback, 1) do
    opts = Keyword.validate!(opts, [:establish_timeout, :cleanup_timeout])
    establish = finite!(opts, :establish_timeout, 30_000)
    cleanup = finite!(opts, :cleanup_timeout, 5_000)
    validate_client_opts!(client_opts)
    deadline = now() + establish
    token = make_ref()

    with {:ok, guardian} <-
           GenServer.start(__MODULE__, {self(), token, client_opts, deadline, cleanup}) do
      scope = {guardian, token, deadline}

      case control(scope, :ready, deadline) do
        {:ok, client} -> callback(scope, client, cleanup, callback)
        error -> connection_failure(scope, cleanup, error)
      end
    end
  end

  defp callback(scope, client, cleanup, fun) do
    try do
      value = fun.(client)

      case finish(scope, cleanup) do
        :ok -> {:ok, value}
        {:error, reason} -> {:error, {:cleanup_failed, reason, value}}
      end
    catch
      kind, reason ->
        stack = __STACKTRACE__

        if finish(scope, cleanup) != :ok,
          do:
            :telemetry.execute([:arbor_acp, :client, :scope_cleanup_failed], %{}, %{
              callback_failed: true
            })

        :erlang.raise(kind, reason, stack)
    end
  end

  defp connection_failure(scope, cleanup, error) do
    case finish(scope, cleanup) do
      :ok -> error
      failed -> {:error, {:connection_cleanup_failed, error, failed}}
    end
  end

  defp finish(scope, cleanup) do
    deadline = now() + cleanup
    control(scope, {:finish, deadline}, deadline)
  end

  def register(nil, _role), do: :ok
  def register(scope, role), do: register(scope, role, self())
  def register(nil, _role, _pid), do: :ok

  def register({_guardian, _token, deadline} = scope, role, pid),
    do: control(scope, {:register, role, pid}, deadline)

  def transport(nil, _mod, _state), do: :ok

  def transport({_guardian, _token, deadline} = scope, mod, state),
    do: control(scope, {:transport, mod, state}, deadline)

  def closed(nil, _result), do: :ok
  def closed({guardian, token, _deadline}, result), do: send(guardian, {:closed, token, result})

  def monitor(nil), do: nil
  def monitor({guardian, _token, _deadline}), do: Process.monitor(guardian)

  defp control({guardian, token, _establish}, request, deadline) do
    GenServer.call(guardian, {token, request}, remaining(deadline))
  catch
    :exit, {:timeout, _call} -> {:error, :connection_scope_timeout}
    :exit, {:noproc, _call} -> {:error, :connection_scope_closed}
    :exit, _reason -> {:error, :connection_scope_closed}
  end

  @impl true
  def init({owner, token, client_opts, deadline, cleanup}) do
    guardian = self()
    owner_ref = Process.monitor(owner)

    {constructor, constructor_ref} =
      spawn_monitor(fn ->
        scope = {guardian, token, deadline}
        client_opts = Keyword.put(client_opts, :_connection_scope, scope)
        gen_opts = [timeout: remaining(deadline)] ++ Keyword.take(client_opts, [:name])
        result = GenServer.start(Client, Keyword.delete(client_opts, :name), gen_opts)
        send(guardian, {:started, token, result})
      end)

    timer = Process.send_after(self(), :establish_timeout, remaining(deadline))

    {:ok,
     %{
       owner: owner,
       owner_ref: owner_ref,
       token: token,
       deadline: deadline,
       cleanup_ms: cleanup,
       constructor: constructor,
       constructor_ref: constructor_ref,
       constructor_done: false,
       timer: timer,
       phase: :starting,
       ready: nil,
       ready_from: nil,
       finish_from: nil,
       owned: %{},
       roles: %{},
       transport: nil,
       worker: nil,
       worker_ref: nil,
       cleanup: nil,
       cleanup_confirmed: false,
       cleanup_error: nil
     }}
  end

  @impl true
  def handle_call(
        {token, {:register, role, pid}},
        _from,
        %{token: token, phase: :starting} = state
      )
      when role in [:client, :handler, :receiver] and is_pid(pid) do
    if remaining(state.deadline) > 0 and not Map.has_key?(state.roles, role) do
      monitor = Process.monitor(pid)

      {:reply, :ok,
       %{
         state
         | roles: Map.put(state.roles, role, pid),
           owned: Map.put(state.owned, monitor, pid)
       }}
    else
      {:reply, {:error, :connection_scope_closed}, state}
    end
  end

  def handle_call(
        {token, {:transport, mod, transport}},
        _from,
        %{token: token, phase: :starting} = state
      ),
      do: {:reply, :ok, %{state | transport: {mod, transport}}}

  def handle_call({token, :ready}, from, %{token: token, phase: :starting} = state),
    do: {:noreply, %{state | ready_from: from}}

  def handle_call({token, :ready}, _from, %{token: token} = state),
    do: {:reply, state.ready, state}

  def handle_call({token, {:finish, _deadline}}, _from, %{token: token, phase: :closed} = state),
    do: {:stop, :normal, outcome(state), state}

  def handle_call({token, {:finish, deadline}}, from, %{token: token} = state),
    do: {:noreply, begin_cleanup(%{state | finish_from: from}, deadline)}

  def handle_call(_request, _from, state), do: {:reply, {:error, :connection_scope_closed}, state}

  @impl true
  def handle_info({:started, token, result}, %{token: token, phase: :starting} = state) do
    Process.cancel_timer(state.timer)
    if state.ready_from, do: GenServer.reply(state.ready_from, result)
    {:noreply, %{state | ready: result, ready_from: nil, phase: :active, constructor_done: true}}
  end

  def handle_info(:establish_timeout, %{phase: :starting} = state) do
    error = {:error, :connection_scope_timeout}
    if state.ready_from, do: GenServer.reply(state.ready_from, error)
    state = %{state | ready: error, ready_from: nil}
    {:noreply, begin_cleanup(state, now() + state.cleanup_ms)}
  end

  def handle_info({:closed, token, :ok}, %{token: token} = state),
    do: {:noreply, %{state | cleanup_confirmed: true}}

  def handle_info({:closed, token, {:error, _reason} = error}, %{token: token} = state),
    do: {:noreply, %{state | cleanup_error: state.cleanup_error || error}}

  def handle_info(
        {:cleanup, token, result, confirmed?},
        %{token: token, phase: :closing} = state
      ),
      do:
        complete(%{
          state
          | cleanup: result,
            cleanup_confirmed: state.cleanup_confirmed or confirmed?
        })

  def handle_info(:cleanup_timeout, %{phase: :closing} = state) do
    kill_owned(state)
    if state.worker, do: Process.exit(state.worker, :kill)
    complete(%{state | phase: :closed, cleanup: {:error, :connection_scope_cleanup_timeout}})
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    if state.phase == :closed,
      do: {:stop, :normal, state},
      else: {:noreply, begin_cleanup(state, now() + state.cleanup_ms)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    state =
      cond do
        ref == state.constructor_ref ->
          state = %{state | constructor: nil, constructor_ref: nil}

          if state.phase == :starting do
            error = {:error, {:connection_start_failed, reason}}
            if state.ready_from, do: GenServer.reply(state.ready_from, error)
            %{state | ready: error, ready_from: nil, phase: :active}
          else
            state
          end

        ref == state.worker_ref ->
          result = state.cleanup || {:error, {:cleanup_worker_exited, reason}}
          %{state | worker: nil, worker_ref: nil, cleanup: result}

        true ->
          %{state | owned: Map.delete(state.owned, ref)}
      end

    complete(state)
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp begin_cleanup(%{phase: phase} = state, _deadline) when phase in [:closing, :closed],
    do: state

  defp begin_cleanup(state, deadline) do
    Process.cancel_timer(state.timer)
    guardian = self()
    if state.constructor, do: Process.exit(state.constructor, :kill)

    {worker, worker_ref} =
      spawn_monitor(fn ->
        {result, confirmed?} = cleanup_owned(state, deadline)
        send(guardian, {:cleanup, state.token, result, confirmed?})
      end)

    timer = Process.send_after(self(), :cleanup_timeout, remaining(deadline))
    %{state | phase: :closing, timer: timer, worker: worker, worker_ref: worker_ref}
  end

  defp cleanup_owned(state, deadline) do
    client = Map.get(state.roles, :client)

    {result, confirmed?} =
      if state.constructor_done and is_pid(client) and Process.alive?(client) do
        result = Client.stop(client, :normal, timeout: remaining(deadline))
        confirm_stop(result, state.transport)
      else
        kill_owned(state)
        result = close_transport(state.transport, state.constructor_done)
        {result, result == :ok}
      end

    if result != :ok, do: kill_owned(state)
    {result, confirmed?}
  catch
    kind, _reason ->
      kill_owned(state)
      {{:error, {:connection_scope_cleanup_failed, kind}}, false}
  end

  # stop/3 is intentionally idempotent for a dead client. Recheck a native
  # receipt so death between the liveness check and stop cannot imply IO cleanup.
  defp confirm_stop(:ok, {Stdio, transport}) do
    result = Stdio.close(transport)
    {result, result == :ok}
  end

  # Custom close confirmation arrives before the client's monitored DOWN.
  # Completion waits for that DOWN; absent confirmation remains an error.
  defp confirm_stop(result, _transport), do: {result, false}

  defp close_transport(nil, true), do: :ok
  defp close_transport(nil, false), do: {:error, :connection_cleanup_unconfirmed}

  defp close_transport({mod, transport}, _completed) do
    case mod.close(transport) do
      :ok -> :ok
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_close_result}
    end
  end

  defp kill_owned(state) do
    Enum.each(state.owned, fn {_ref, pid} -> Process.exit(pid, :kill) end)
  end

  defp complete(
         %{phase: :closing, cleanup: result, worker: nil, constructor: nil, owned: owned} = state
       )
       when not is_nil(result) and map_size(owned) == 0 do
    Process.cancel_timer(state.timer)
    complete(%{state | phase: :closed})
  end

  defp complete(%{phase: :closed} = state) do
    cond do
      state.finish_from ->
        {:stop, :normal, outcome(state), state} |> reply_finished(state.finish_from)

      not Process.alive?(state.owner) ->
        {:stop, :normal, state}

      true ->
        {:noreply, state}
    end
  end

  defp complete(state), do: {:noreply, state}

  defp reply_finished({:stop, reason, result, state}, from) do
    GenServer.reply(from, result)
    {:stop, reason, state}
  end

  defp outcome(%{cleanup_error: {:error, _reason} = error}), do: error

  defp outcome(%{cleanup: :ok, cleanup_confirmed: false}),
    do: {:error, :connection_cleanup_unconfirmed}

  defp outcome(state), do: state.cleanup
  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)

  defp finite!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 and value <= 2_147_483_647 -> value
      _invalid -> raise ArgumentError, "#{key} must be positive finite milliseconds"
    end
  end

  defp validate_client_opts!(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "client options must be a keyword list")

    if Keyword.has_key?(opts, :_connection_scope) or Keyword.has_key?(opts, :owner),
      do: raise(ArgumentError, "connection scopes own their client and transport")

    name = Keyword.get(opts, :name)

    unless is_nil(name) or is_atom(name),
      do: raise(ArgumentError, "connection scope names must be local atoms")
  end
end
