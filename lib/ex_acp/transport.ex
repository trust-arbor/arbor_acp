defmodule ExACP.Transport do
  @moduledoc """
  Behaviour for ACP transports.

  A transport moves JSON-RPC frames between an `ExACP.Client` (or
  `ExACP.Agent`) and its peer. `ExACP.Transport.Stdio` spawns an agent
  subprocess, `ExACP.AdapterTransport` drives a non-native agent through an
  `ExACP.AdapterBridge`, and `ExACP.Agent.Transport.Memory` connects a client
  and an agent in the same VM.

  The callback shape is identical to `ExMCP.Transport`, so any module that
  implements that behaviour also works here.
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
  ACP-shaped map/list for in-memory transports. Should return
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
  @optional_callbacks connected?: 1, capabilities: 1, subscribe: 2

  @doc """
  Check if a transport module supports the push (subscribe) model.
  """
  @spec supports_push?(module()) :: boolean()
  def supports_push?(transport_mod) do
    function_exported?(transport_mod, :subscribe, 2)
  end
end
