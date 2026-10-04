defmodule Arbor.ACP.Transport.Stdio do
  @moduledoc """
  ACP JSON-RPC over an owned child subprocess.

  Child ownership, effective PATH/environment resolution, byte framing and
  finite cleanup belong to `Arbor.RPC`. This wrapper validates outbound ACP
  frames, filters native stdout noise and emits protocol telemetry. Receive
  tasks share an opaque handle without taking Port ownership. An explicit
  `:owner` can give a temporary connector's child to its long-lived client.

  Pull reads retain one absolute deadline across filtered frames. Push callers
  receive neutral generation-tagged RPC events and use `event/2`, `frame/1` and
  `ack/2`; they acknowledge only after bounded protocol admission.
  """

  @behaviour Arbor.ACP.Transport
  require Logger

  alias Arbor.ACP.Internal.Options
  alias Arbor.RPC.{FramedStream, LogSummary, StdioFraming, Subprocess}

  @default_max_frame_bytes 1_048_576
  defstruct [:subprocess, :os_pid, :subscriber, max_frame_bytes: @default_max_frame_bytes]

  @impl true
  def connect(opts) do
    limit = Options.positive_integer(opts, :max_frame_bytes, @default_max_frame_bytes)

    child_opts =
      opts |> Keyword.put(:max_frame_bytes, limit) |> Keyword.put_new(:max_write_bytes, limit + 1)

    case Subprocess.open(Keyword.get(opts, :command, []), child_opts) do
      {:ok, handle} ->
        [command | _] = Keyword.fetch!(opts, :command)

        :telemetry.execute([:arbor_acp, :transport, :connection, :opened], %{}, %{
          transport: :stdio,
          command_basename: Path.basename(command),
          command_hash: LogSummary.fingerprint(command)
        })

        {:ok,
         %__MODULE__{
           subprocess: handle,
           os_pid: Subprocess.os_pid(handle),
           max_frame_bytes: limit
         }}

      {:error, {:invalid_environment_policy, _} = reason} ->
        {:error, reason}

      {:error, {:invalid_process_group, _} = reason} ->
        {:error, reason}

      {:error, {:invalid_option, :process_group}} ->
        {:error, {:invalid_process_group, Keyword.get(opts, :process_group)}}

      {:error, reason} ->
        {:error, {:connection_error, {:spawn_failed, reason}}}
    end
  end

  @impl true
  def send_message(message, %__MODULE__{} = state) when is_binary(message) do
    cond do
      byte_size(message) > state.max_frame_bytes ->
        {:error, :frame_too_large}

      String.contains?(message, ["\n", "\r"]) ->
        {:error, {:validation_error, :embedded_newline}}

      not match?({:ok, _}, Jason.decode(message)) ->
        {:error, {:validation_error, :invalid_json}}

      true ->
        case Subprocess.write(state.subprocess, message <> "\n") do
          :ok ->
            :telemetry.execute(
              [:arbor_acp, :transport, :message, :sent],
              %{size: byte_size(message)},
              %{transport: :stdio}
            )

            {:ok, state}

          {:error, reason} ->
            {:error, {:transport_error, {:send_failed, reason}}}
        end
    end
  end

  def send_message(_message, _state), do: {:error, {:validation_error, :invalid_json}}

  @impl true
  def receive_message(state), do: receive_message(state, :infinity)

  @doc "Receive within one total timeout, including skipped banners and blanks."
  @spec receive_message(%__MODULE__{}, timeout()) ::
          {:ok, binary(), %__MODULE__{}} | {:error, term()}
  def receive_message(state, :infinity), do: receive_until(state, :infinity, false)

  def receive_message(state, timeout) when is_integer(timeout) and timeout >= 0,
    do: receive_until(state, System.monotonic_time(:millisecond) + timeout, timeout == 0)

  def receive_message(_state, _timeout), do: {:error, :invalid_timeout}

  defp receive_until(state, deadline, buffered_only) do
    case FramedStream.next_until(state.subprocess, deadline, buffered_only: buffered_only) do
      {:ok, bytes} ->
        case frame(bytes) do
          {:ok, json} ->
            received(json)
            {:ok, json, state}

          :ignore ->
            receive_until(state, deadline, buffered_only)

          {:error, reason} ->
            cleanup = close(state)

            if cleanup == :ok,
              do: {:error, reason},
              else: {:error, {:cleanup_failed, reason, cleanup}}
        end

      {:closed, reason, _remainder} ->
        {:error, {:connection_error, closed_reason(reason)}}

      {:error, :timeout} ->
        {:error, :handshake_timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def close(%__MODULE__{subprocess: handle}) do
    :telemetry.execute([:arbor_acp, :transport, :connection, :closed], %{}, %{transport: :stdio})
    Subprocess.close(handle)
  end

  @impl true
  def connected?(%__MODULE__{subprocess: nil}), do: false
  def connected?(%__MODULE__{subprocess: handle}), do: Subprocess.connected?(handle)

  @impl true
  def linked_processes(%__MODULE__{subprocess: nil}), do: []
  def linked_processes(%__MODULE__{subprocess: handle}), do: Subprocess.linked_processes(handle)

  @doc "Subscribe directly with one frame of credit; acknowledge after protocol admission."
  @impl true
  def subscribe(pid, %__MODULE__{subprocess: handle} = state) do
    case FramedStream.subscribe(handle, pid, window: 1) do
      :ok -> {:ok, %{state | subscriber: pid}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def capabilities(_state), do: [:push]

  @doc "Match neutral shared events to this connection's generation."
  def event(%__MODULE__{subprocess: nil}, _message), do: :ignore

  def event(%__MODULE__{subprocess: handle}, {:arbor_rpc, generation, event}) do
    if generation == Subprocess.identity(handle), do: event, else: :ignore
  end

  def event(_state, _message), do: :ignore

  @doc "Acknowledge a received frame after processing/admission into bounded output."
  def ack(%__MODULE__{subprocess: handle}, token), do: FramedStream.ack(handle, token)

  @doc "The opaque identity used to reject events from older connections."
  def identity(%__MODULE__{subprocess: handle}), do: Subprocess.identity(handle)

  @doc "Apply ACP stdout framing policy to one complete shared frame."
  def frame(bytes) do
    if String.valid?(bytes) do
      trimmed = bytes |> StdioFraming.strip_bom() |> String.trim()

      if String.starts_with?(trimmed, ["{", "["]) do
        {:ok, trimmed}
      else
        Logger.debug("Skipping non-JSON output", line_shape: LogSummary.describe(trimmed))
        :ignore
      end
    else
      {:error, :invalid_utf8}
    end
  end

  @doc false
  def received(json),
    do:
      :telemetry.execute(
        [:arbor_acp, :transport, :message, :received],
        %{size: byte_size(json)},
        %{transport: :stdio}
      )

  @doc false
  def closed_reason({:exit_status, code}), do: {:process_exited, code}

  def closed_reason({:cleanup_failed, reason, result}),
    do: {:cleanup_failed, closed_reason(reason), result}

  def closed_reason(reason), do: reason
end
