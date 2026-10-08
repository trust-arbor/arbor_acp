defmodule Arbor.ACP.Internal.Call do
  @moduledoc false

  def timeout!(opts, default \\ 5_000) do
    case Keyword.get(opts, :timeout, default) do
      value
      when (is_integer(value) and value >= 0 and value <= 4_294_967_295) or value == :infinity ->
        value

      _invalid ->
        raise ArgumentError, "timeout must be non-negative milliseconds or :infinity"
    end
  end

  def call(server, request, timeout \\ 5_000) do
    GenServer.call(server, request, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, {:noproc, _call} -> {:error, :client_not_alive}
    :exit, {reason, _call} when reason in [:normal, :shutdown] -> {:error, :client_not_alive}
    :exit, {{:shutdown, _reason}, _call} -> {:error, :client_not_alive}
  end

  def status(server, opts) do
    timeout = opts |> Keyword.validate!([:timeout]) |> timeout!()

    case call(server, :status, timeout) do
      value when is_atom(value) -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  def unwrap!({:ok, value}), do: value

  def unwrap!({:error, reason}),
    do: raise(RuntimeError, "ACP status unavailable: #{inspect(reason)}")

  def stop(client, reason, opts) do
    timeout = opts |> Keyword.validate!([:timeout]) |> timeout!()
    if timeout == :infinity, do: raise(ArgumentError, "stop requires a finite timeout")

    if :erlang.external_size(reason) > 4_096,
      do: raise(ArgumentError, "stop reason exceeds 4096 bytes")

    deadline = System.monotonic_time(:millisecond) + timeout

    case GenServer.whereis(client) do
      nil -> :ok
      pid -> stop_pid(pid, reason, deadline)
    end
  end

  defp stop_pid(pid, reason, deadline) do
    monitor = Process.monitor(pid)

    try do
      case call(pid, {:stop, reason}, remaining(deadline)) do
        {:stopping, :ok, handler} ->
          with :ok <- await_stop(pid, monitor, deadline), do: await_handler(handler, deadline)

        {:stopping, {:error, _reason} = error, _handler} ->
          error

        {:error, :client_not_alive} ->
          :ok

        error ->
          error
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await_handler(handler, deadline) when is_pid(handler) do
    monitor = Process.monitor(handler)

    try do
      await_stop(handler, monitor, deadline)
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await_handler(_handler, _deadline), do: :ok

  defp await_stop(pid, monitor, deadline) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      remaining(deadline) -> {:error, :client_shutdown_timeout}
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  def stop_agent(agent, opts) do
    timeout = opts |> Keyword.validate!([:timeout]) |> timeout!()
    if timeout == :infinity, do: raise(ArgumentError, "stop requires a finite timeout")
    GenServer.stop(agent, :normal, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, {:noproc, _call} -> :ok
  end
end
