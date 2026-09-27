defmodule ExACP.Telemetry do
  @moduledoc """
  Telemetry events emitted by ExACP.

  | Event | Emitted by |
  |---|---|
  | `[:ex_acp, :session, :started]` | `ExACP.Client` when `session/new` succeeds |
  | `[:ex_acp, :session, :ended]` | `ExACP.Client` when a session is closed |
  | `[:ex_acp, :prompt, :sent]` | `ExACP.Client` when a prompt is sent |
  | `[:ex_acp, :prompt, :completed]` | `ExACP.Client` when a prompt returns successfully |
  | `[:ex_acp, :request, :received]` | `ExACP.AdapterBridge` before handling each outbound request or notification |
  | `[:ex_acp, :request, :completed]` | `ExACP.AdapterBridge` after handing it to the adapter (not when answered) |
  | `[:ex_acp, :transport, :message_sent]` | `ExACP.AdapterTransport` |
  | `[:ex_acp, :transport, :message_received]` | `ExACP.AdapterTransport` |
  | `[:ex_acp, :transport, :connection, :opened]` | `ExACP.Transport.Stdio` |
  | `[:ex_acp, :transport, :connection, :closed]` | `ExACP.Transport.Stdio` |
  | `[:ex_acp, :transport, :message, :sent]` | `ExACP.Transport.Stdio` |
  | `[:ex_acp, :transport, :message, :received]` | `ExACP.Transport.Stdio` |

  `events/0` returns this list so libraries can attach to every event without
  hard-coding names.
  """

  @events [
    [:ex_acp, :session, :started],
    [:ex_acp, :session, :ended],
    [:ex_acp, :prompt, :sent],
    [:ex_acp, :prompt, :completed],
    [:ex_acp, :request, :received],
    [:ex_acp, :request, :completed],
    [:ex_acp, :transport, :message_sent],
    [:ex_acp, :transport, :message_received],
    [:ex_acp, :transport, :connection, :opened],
    [:ex_acp, :transport, :connection, :closed],
    [:ex_acp, :transport, :message, :sent],
    [:ex_acp, :transport, :message, :received]
  ]

  @doc "Every telemetry event name ExACP emits."
  @spec events() :: [[atom(), ...]]
  def events, do: @events
end
