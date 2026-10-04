defmodule ArborACP.Transport do
  @moduledoc """
  Transport callbacks for ACP clients and adapter bridges.

  The built-in `:stdio` transport exchanges JSON-RPC frames with a child
  process. Custom transport modules implement the same connection, send,
  receive, and close callbacks. Optional push delivery sends
  `{:transport_event, message}` to a subscribed process.
  """

  @type state :: any()
  @type message :: String.t() | map() | list()
  @type opts :: keyword()

  @doc """
  Establishes a connection for the transport.

  Options are transport-specific. Should return `{:ok, state}`
  where state contains any necessary connection information.
  """
  @callback connect(opts()) :: {:ok, state()} | {:error, any()}

  @doc """
  Sends a message through the transport.

  The message will be a JSON-encoded string for wire transports, or an
  ACP-shaped map/list for local BEAM transports. Should return
  `{:ok, new_state}` on success.

  Synchronous request/response transports (e.g. HTTP POST without SSE
  streaming) may instead return `{:ok, new_state, response}` where
  `response` is the response body delivered inline — either a raw JSON
  string or an already-decoded map. Callers must be prepared to handle
  both the 2-tuple and 3-tuple success shapes; transports that deliver
  responses asynchronously (via `receive_message/1` or `subscribe/2`)
  should return the 2-tuple.
  """
  @callback send_message(message(), state()) ::
              {:ok, state()} | {:ok, state(), response :: binary() | map()} | {:error, any()}

  @doc """
  Receives a message from the transport.

  This should block until a message is available. Returns
  `{:ok, message, new_state}` where message is a JSON string or ACP-shaped term.

  Note: When `subscribe/2` is used, `receive_message/1` may not be called.
  Transports should still implement it for backwards compatibility.
  """
  @callback receive_message(state()) :: {:ok, message(), state()} | {:error, any()}

  @doc """
  Closes the transport connection.

  Should clean up any resources and return `:ok`.
  """
  @callback close(state()) :: :ok

  @doc """
  Optional callback to check if the transport is still connected.

  Default implementation always returns true.
  """
  @callback connected?(state()) :: boolean()

  @doc """
  Optional: Subscribe a process to receive transport events.

  When implemented, the transport pushes messages to the subscriber pid as:
  - `{:transport_event, message}` — a received message (JSON string or map)
  - `{:transport_closed, reason}` — transport connection closed
  - `{:transport_error, reason}` — transport error occurred

  This enables the push (event-driven) model, eliminating the need for a
  receiver task that polls `receive_message/1`.

  Returns `{:ok, new_state}` on success.
  """
  @callback subscribe(pid(), state()) :: {:ok, state()} | {:error, any()}

  @doc """
  Optional callback to declare transport capabilities.

  Returns a list of capability atoms that indicate special features
  supported by this transport. Clients can use this information to
  optimize their communication strategy.

  ## Capabilities

  - `:push` - Transport supports `subscribe/2` for event-driven message delivery
  - `:compression` - Transport supports message compression (future)
  - `:encryption` - Transport supports message encryption (future)

  ## Examples

      # Transport with push delivery
      def capabilities(_state), do: [:push]

      # Transport with no special capabilities (default)
      def capabilities(_state), do: []

  Default implementation returns an empty list (no special capabilities).
  """
  @callback capabilities(state()) :: [atom()]

  @doc """
  Optional: the processes and ports this transport has linked to the process
  that called `connect/1` or `subscribe/2` (for example a reader it
  `spawn_link`ed, or a port it opened).

  `ArborACP.Client` traps exits. An abnormal exit signal from one of these is
  treated as the transport failing (pending requests fail and the reconnect
  path takes over); an abnormal exit signal from any other linked process
  stops the client, exactly as it would stop a process that does not trap
  exits. A transport that links helpers to its caller without listing them
  here makes their crash stop the client.

  Default implementation returns an empty list.
  """
  @callback linked_processes(state()) :: [pid() | port()]
  @optional_callbacks connected?: 1, capabilities: 1, subscribe: 2, linked_processes: 1

  @doc """
  Check if a transport module supports the push (subscribe) model.
  """
  @spec supports_push?(module()) :: boolean()
  def supports_push?(transport_mod) do
    function_exported?(transport_mod, :subscribe, 2)
  end

  @doc """
  Returns the processes and ports `transport_mod` linked to its caller for
  `transport_state`, or `[]` when the transport does not say.
  """
  @spec linked_processes(module() | nil, state()) :: [pid() | port()]
  def linked_processes(nil, _transport_state), do: []
  def linked_processes(_transport_mod, nil), do: []

  def linked_processes(transport_mod, transport_state) do
    if function_exported?(transport_mod, :linked_processes, 1) do
      transport_state
      |> transport_mod.linked_processes()
      |> Enum.filter(&(is_pid(&1) or is_port(&1)))
    else
      []
    end
  rescue
    _error -> []
  end

  @doc "Resolve `:stdio` or a custom transport module."
  @spec get_transport(:stdio | module()) :: module()
  def get_transport(:stdio), do: ArborACP.Transport.Stdio
  def get_transport(module) when is_atom(module), do: module
end
