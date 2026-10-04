defmodule Arbor.ACP.Transport.Stdio do
  @moduledoc """
  ACP stdio transport for child processes.

  Exchanges one JSON-RPC message per line, rejects embedded frame delimiters,
  bounds receive buffers, and starts children with an isolated environment by
  default. Explicit environment variables take precedence. This mechanical
  wrapper preserves current subprocess fixes while shared lifecycle and stdio
  logging convergence remain v2 release gates.
  """

  @behaviour Arbor.ACP.Transport

  require Logger

  alias Arbor.RPC.Internal.LineBuffer
  alias Arbor.RPC.LogSummary
  alias Arbor.ACP.Internal.Options
  alias Arbor.RPC.PortEnvironment

  @termination_poll_ms 10
  @termination_grace_attempts 10
  @default_max_frame_bytes 1_048_576
  defstruct [
    :port,
    :os_pid,
    :line_buffer,
    :subscriber,
    :reader_pid,
    max_frame_bytes: @default_max_frame_bytes,
    process_group: false
  ]

  @impl true
  def connect(opts) do
    with :ok <- PortEnvironment.validate_policy(opts),
         :ok <- validate_process_group(opts) do
      do_connect(opts)
    end
  end

  defp validate_process_group(opts) do
    case Keyword.get(opts, :process_group, false) do
      flag when is_boolean(flag) -> :ok
      invalid -> {:error, {:invalid_process_group, invalid}}
    end
  end

  defp do_connect(opts) do
    command = Keyword.fetch!(opts, :command)

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :hide,
      :stream,
      line: 1_000_000,
      args: tl(command),
      env: safe_env(opts)
    ]

    port_opts =
      case Keyword.get(opts, :cd) do
        nil -> port_opts
        dir -> [{:cd, to_charlist(dir)} | port_opts]
      end

    executable = hd(command)

    # Try to find the executable in common locations if it's not a full path
    executable_path =
      if Path.type(executable) == :absolute do
        executable
      else
        case find_executable(executable, PortEnvironment.child_path(opts)) do
          nil ->
            # Try common locations for node/npm/npx on macOS
            common_paths = [
              "/opt/homebrew/bin/#{executable}",
              "/usr/local/bin/#{executable}",
              "/usr/bin/#{executable}",
              "#{System.get_env("HOME")}/.nvm/versions/node/#{System.get_env("NODE_VERSION", "*")}/bin/#{executable}"
            ]

            Enum.find(common_paths, executable, &File.exists?/1)

          path ->
            path
        end
      end

    try do
      port = Port.open({:spawn_executable, to_charlist(executable_path)}, port_opts)

      state = %__MODULE__{
        port: port,
        os_pid: port_os_pid(port),
        line_buffer: "",
        max_frame_bytes:
          Options.positive_integer(opts, :max_frame_bytes, @default_max_frame_bytes),
        process_group: Keyword.get(opts, :process_group, false)
      }

      :telemetry.execute([:arbor_acp, :transport, :connection, :opened], %{}, %{
        transport: :stdio,
        command_basename: Path.basename(executable_path),
        command_hash: LogSummary.fingerprint(executable_path)
      })

      {:ok, state}
    catch
      :error, reason ->
        {:error, {:connection_error, {:spawn_failed, reason}}}
    end
  end

  @impl true
  def send_message(message, %__MODULE__{port: port} = state) do
    # Check if message contains external resource requests that need security validation
    case request_within_limit(message, state.max_frame_bytes) do
      {:error, :frame_too_large} = error ->
        error

      :ok ->
        do_send_message(message, port, state)
    end
  end

  defp do_send_message(message, port, state) do
    cond do
      String.contains?(message, ["\n", "\r"]) ->
        {:error, {:validation_error, :embedded_newline}}

      not match?({:ok, _}, Jason.decode(message)) ->
        {:error, {:validation_error, :invalid_json}}

      true ->
        :telemetry.execute(
          [:arbor_acp, :transport, :message, :sent],
          %{size: byte_size(message)},
          %{transport: :stdio}
        )

        try do
          Port.command(port, message <> "\n")
          {:ok, state}
        catch
          :error, reason -> {:error, {:transport_error, {:send_failed, reason}}}
        end
    end
  end

  @impl true
  def receive_message(%__MODULE__{} = state) do
    receive_message(state, :infinity)
  end

  @doc """
  Receives a single message, waiting at most `timeout` milliseconds.

  Callers must run this in the process that owns the port (or in one that may
  take ownership): port ownership is transferred to the caller, and an OTP port
  is closed when its owner exits. Running it in a short-lived helper process
  would therefore kill the spawned program — which is why the handshake path
  uses this timeout-aware clause in-process instead of wrapping
  `receive_message/1` in a task.
  """
  @spec receive_message(%__MODULE__{}, timeout()) ::
          {:ok, binary(), %__MODULE__{}} | {:error, any()}
  def receive_message(%__MODULE__{port: port} = state, timeout) do
    take_ownership(port)
    receive_loop(state, timeout)
  end

  # Transfer port ownership to this process if needed. A port that has
  # already closed cannot be connected; its last messages (the exit status
  # among them) are already in the owner's mailbox for receive_loop/2.
  defp take_ownership(port) do
    case Port.info(port, :connected) do
      {:connected, owner} when owner == self() -> :ok
      {:connected, _other} -> Port.connect(port, self())
      nil -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def close(%__MODULE__{port: port, os_pid: os_pid, reader_pid: reader_pid} = state) do
    :telemetry.execute([:arbor_acp, :transport, :connection, :closed], %{}, %{transport: :stdio})

    # Close the port before killing the reader: port_close exits the port
    # with reason :normal, which linked processes ignore, whereas killing
    # the port's owner (the reader, in push mode) first would cascade a
    # :killed exit through the port to its other linked processes.
    close_port(port)

    if is_pid(reader_pid) and Process.alive?(reader_pid) do
      # The reader is a plain spawn_link receive loop that does not trap
      # exits, so an exit signal with reason :normal would be silently
      # ignored and leak the process. Unlink first so the kill cannot
      # cascade to the caller, then terminate it unconditionally.
      Process.unlink(reader_pid)
      Process.exit(reader_pid, :kill)
    end

    # Port.close/1 tears down the Erlang port, but on Unix it does not
    # guarantee that the spawned OS process exits. Explicitly terminate the
    # child after detaching the reader so repeated stdio connections cannot
    # leak servers and exhaust the runner's process/thread budget.
    terminate_os_process(signal_target(os_pid, state.process_group))

    :ok
  end

  # A negative pid addresses the process group the port program leads.
  defp signal_target(nil, _process_group), do: nil
  defp signal_target(os_pid, true), do: {:group, os_pid}
  defp signal_target(os_pid, false), do: os_pid

  # A server that exits on its own is not signalled by anyone, so what it
  # left running in its group would outlive the connection. The group keeps
  # the leader's pid as its id after the leader is gone; a pid is not reused
  # while a group with that id still has members, so the risk accepted here
  # is only a group that emptied and whose id was handed to a new group
  # leader within the grace period. Runs in its own process so neither the
  # client nor the reader waits for it.
  defp reap_group(%__MODULE__{process_group: true, os_pid: os_pid}) when is_integer(os_pid) do
    reap_group(os_pid)
  end

  defp reap_group(%__MODULE__{}), do: :ok

  defp reap_group(os_pid) when is_integer(os_pid) do
    spawn(fn -> terminate_os_process({:group, os_pid}) end)
    :ok
  end

  defp reap_group(_os_pid), do: :ok

  # Tolerate a port that is nil or already closed (e.g. the spawned process
  # exited on its own before close/1 was called).
  defp close_port(port) do
    Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _other -> nil
    end
  end

  defp terminate_os_process(nil), do: :ok

  defp terminate_os_process(target) do
    case :os.type() do
      {:win32, _name} ->
        run_command("taskkill", ["/PID", Integer.to_string(target_pid(target)), "/T", "/F"])

      {:unix, _name} ->
        signal_process(target, "TERM")

        unless wait_for_process_exit(target, @termination_grace_attempts) do
          signal_process(target, "KILL")
        end
    end

    :ok
  end

  defp target_pid({:group, os_pid}), do: os_pid
  defp target_pid(os_pid), do: os_pid

  # `kill` addresses a process group by the negated group id; `--` keeps the
  # negative number from being read as an option.
  defp kill_args(signal, {:group, os_pid}), do: ["-#{signal}", "--", "-#{os_pid}"]
  defp kill_args(signal, os_pid), do: ["-#{signal}", Integer.to_string(os_pid)]

  defp wait_for_process_exit(_os_pid, 0), do: false

  defp wait_for_process_exit(os_pid, attempts_left) do
    if os_process_alive?(os_pid) do
      Process.sleep(@termination_poll_ms)
      wait_for_process_exit(os_pid, attempts_left - 1)
    else
      true
    end
  end

  # For a group, true while any member is left.
  defp os_process_alive?(target) do
    case run_command("kill", kill_args("0", target)) do
      {_output, 0} -> true
      _other -> false
    end
  end

  defp signal_process(target, signal) do
    run_command("kill", kill_args(signal, target))
    :ok
  end

  defp find_executable(name, nil), do: System.find_executable(name)

  # :os.find_executable/2 searches an explicit path with the platform's own
  # rules: its path separator, the execute bit on Unix, and the executable
  # extensions on Windows. A name with a directory is not searched for.
  defp find_executable(name, path) do
    if String.contains?(name, ["/", "\\"]) do
      System.find_executable(name)
    else
      case :os.find_executable(String.to_charlist(name), String.to_charlist(path)) do
        false -> nil
        found -> List.to_string(found)
      end
    end
  end

  defp run_command(command, args) do
    case System.find_executable(command) do
      nil -> {"", 127}
      executable -> System.cmd(executable, args, stderr_to_stdout: true)
    end
  rescue
    _error -> {"", 1}
  end

  @impl true
  def connected?(%__MODULE__{port: port}) do
    Port.info(port) != nil
  end

  # The port is linked to the process that opened it, and stays linked to it
  # after subscribe/2 hands ownership to the reader, which is spawn_linked.
  @impl true
  def linked_processes(%__MODULE__{port: port, reader_pid: reader_pid}) do
    Enum.filter([port, reader_pid], &(is_port(&1) or is_pid(&1)))
  end

  @doc """
  Subscribe to receive transport events (push model).

  Spawns an internal reader process that takes over port ownership,
  reads and parses JSON messages, and pushes them to the subscriber.
  """
  @impl true
  def subscribe(pid, %__MODULE__{port: port} = state) when is_pid(pid) do
    # Spawn the reader first, then transfer port ownership from the caller
    # (the current port owner). Transferring from the caller instead of from
    # inside the reader avoids a race where the port dies before the reader
    # is scheduled, which would crash the subscriber through the link.
    group = if state.process_group, do: state.os_pid

    reader =
      spawn_link(fn ->
        receive do
          :port_transferred -> stdio_reader_loop(port, "", pid, state.max_frame_bytes, group)
        end
      end)

    try do
      Port.connect(port, reader)
      send(reader, :port_transferred)
      {:ok, %{state | subscriber: pid, reader_pid: reader}}
    rescue
      ArgumentError ->
        Process.unlink(reader)
        Process.exit(reader, :kill)
        {:error, :port_closed}
    end
  end

  @impl true
  def capabilities(%__MODULE__{}), do: [:push]

  # Testing support - expose process_data for unit tests
  @doc false
  def process_data(data, state), do: do_process_data(data, state)

  # Private functions

  # `timeout` bounds the wait for a *complete* line: each partial chunk resets
  # the remaining budget only by the time already spent, so a slow-drip server
  # cannot extend the deadline indefinitely.
  defp receive_loop(state, timeout) do
    started = System.monotonic_time(:millisecond)

    receive do
      {port, {:data, data}} when port == state.port ->
        do_process_data(data, state, remaining(timeout, started))

      {port, {:exit_status, status}} when port == state.port ->
        reap_group(state)
        {:error, {:connection_error, {:process_exited, status}}}

      {port, :eof} when port == state.port ->
        {:error, {:connection_error, :eof}}
    after
      timeout -> {:error, :handshake_timeout}
    end
  end

  defp remaining(:infinity, _started), do: :infinity

  defp remaining(timeout, started) do
    max(timeout - (System.monotonic_time(:millisecond) - started), 0)
  end

  defp do_process_data(data, state, timeout \\ :infinity) do
    # Handle both binary and :eol tuple format from port
    binary_data =
      case data do
        {:eol, line} -> line <> "\n"
        {:noeol, line} -> line
        binary when is_binary(binary) -> binary
        _ -> ""
      end

    # Accumulate data until we have a complete line, but never retain an
    # attacker-controlled delimiter-free frame beyond the configured bound.
    with {:ok, new_buffer} <- append_frame(state.line_buffer, binary_data, state.max_frame_bytes) do
      process_received_buffer(new_buffer, state, timeout)
    end
  end

  defp process_received_buffer(new_buffer, state, timeout) do
    case String.split(new_buffer, "\n", parts: 2) do
      [line, rest] ->
        # We have a complete line
        trimmed = String.trim(line)

        cond do
          trimmed == "" ->
            # Empty line, continue
            receive_loop(%{state | line_buffer: rest}, timeout)

          # Skip non-JSON output like "Secure MCP Filesystem Server..."
          not String.starts_with?(trimmed, "{") and not String.starts_with?(trimmed, "[") ->
            Logger.debug("Skipping non-JSON output", line_shape: LogSummary.describe(trimmed))
            receive_loop(%{state | line_buffer: rest}, timeout)

          true ->
            # Return the JSON line and update state
            :telemetry.execute(
              [:arbor_acp, :transport, :message, :received],
              %{size: byte_size(trimmed)},
              %{transport: :stdio}
            )

            {:ok, trimmed, %{state | line_buffer: rest}}
        end

      [partial] ->
        # No complete line yet, keep buffering
        receive_loop(%{state | line_buffer: partial}, timeout)
    end
  end

  # Internal reader process for push mode.
  # Reads port data, buffers lines, parses JSON, pushes to subscriber.
  defp stdio_reader_loop(port, line_buffer, subscriber, max_frame_bytes, group) do
    receive do
      {^port, {:data, data}} ->
        binary_data =
          case data do
            {:eol, line} -> line <> "\n"
            {:noeol, line} -> line
            binary when is_binary(binary) -> binary
            _ -> ""
          end

        case append_frame(line_buffer, binary_data, max_frame_bytes) do
          {:ok, new_buffer} ->
            remaining = process_buffer(new_buffer, subscriber, max_frame_bytes)
            stdio_reader_loop(port, remaining, subscriber, max_frame_bytes, group)

          {:error, :frame_too_large} ->
            Kernel.send(subscriber, {:transport_closed, :frame_too_large})
            close_port(port)
        end

      {^port, {:exit_status, status}} ->
        Kernel.send(subscriber, {:transport_closed, {:process_exited, status}})
        reap_group(group)

      {^port, :eof} ->
        Kernel.send(subscriber, {:transport_closed, :eof})
    end
  end

  # Process buffered data, sending complete JSON messages to subscriber.
  # Returns remaining incomplete buffer.
  defp process_buffer(buffer, subscriber, max_frame_bytes) do
    {messages, invalid_lines, partial} = LineBuffer.drain_json(buffer)

    Enum.each(messages, fn message ->
      Kernel.send(subscriber, {:transport_event, message})
    end)

    Enum.each(invalid_lines, fn {:invalid_json, line} ->
      Logger.debug("Skipping invalid JSON", line_shape: LogSummary.describe(line))
    end)

    if byte_size(partial) <= max_frame_bytes, do: partial, else: ""
  end

  @doc false
  @spec append_frame(binary(), iodata(), pos_integer()) ::
          {:ok, binary()} | {:error, :frame_too_large}
  def append_frame(buffer, data, limit)
      when is_binary(buffer) and is_integer(limit) and limit > 0 do
    data = IO.iodata_to_binary(data)

    if byte_size(buffer) + byte_size(data) <= limit,
      do: {:ok, buffer <> data},
      else: {:error, :frame_too_large}
  end

  defp request_within_limit(message, limit) when byte_size(message) <= limit, do: :ok
  defp request_within_limit(_message, _limit), do: {:error, :frame_too_large}

  defp safe_env(opts) do
    opts
    |> PortEnvironment.base()
    |> Map.merge(PortEnvironment.normalize(Keyword.get(opts, :env, [])))
    |> PortEnvironment.to_port()
  end
end
