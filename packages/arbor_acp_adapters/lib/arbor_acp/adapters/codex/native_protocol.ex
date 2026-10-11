defmodule Arbor.ACP.Adapters.Codex.NativeProtocol do
  @moduledoc false

  alias Arbor.ACP.Adapters.Codex.Protocol
  alias Arbor.RPC.JSONRPC, as: Envelope

  @request "_arbor/codex/request"
  @notify "_arbor/codex/notify"
  @event "_arbor/codex/event"
  @owned ~w(threadId thread cwd input config approvalPolicy approvalsReviewer sandbox sandboxPolicy permissions runtimeWorkspaceRoots selectedCapabilityRoots environments path excludeTurns initialTurnsPageSize initialTurnsSortDirection)

  def init!(opts) do
    mode = Keyword.get(opts, :native_api, :off)

    unless mode in [:off, :shared, :exclusive],
      do: raise(ArgumentError, "native_api must be :off, :shared, or :exclusive")

    params = Keyword.get(opts, :native_initialize_params, %{})

    unless json_object?(params),
      do: raise(ArgumentError, "native_initialize_params must be a JSON object with string keys")

    limit = Keyword.get(opts, :max_native_pending_requests, 1024)

    unless is_integer(limit) and limit > 0,
      do: raise(ArgumentError, "max_native_pending_requests must be positive")

    opts
  end

  def enabled?(state), do: state.native_api != :off
  def exclusive?(state), do: state.native_api == :exclusive
  def limit(state), do: state.native_pending_limit

  def json_object?(value), do: is_map(value) and json?(value)

  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)
  defp json?(%{__struct__: _}), do: false

  defp json?(value) when is_map(value),
    do: Enum.all?(value, fn {k, v} -> is_binary(k) and String.valid?(k) and json?(v) end)

  defp json?(_value), do: false

  def validate_outbound(%{"method" => "session/" <> _}, state) when is_struct(state) do
    if exclusive?(state), do: {:error, :native_connection_exclusive}, else: :ok
  end

  def validate_outbound(_, _), do: :ok

  def validate_overrides(%{"params" => params}, method)
      when method in ["session/new", "session/load", "session/resume", "session/prompt"] do
    extra = extra_params(params)

    cond do
      extra == %{} ->
        :ok

      not json_object?(extra) ->
        {:error, :invalid_native_params}

      Enum.any?(@owned, &Map.has_key?(extra, &1)) ->
        {:error, :native_params_override_managed_fields}

      true ->
        :ok
    end
  end

  def validate_overrides(_, _), do: :ok

  def overrides(wire_params, params) do
    Map.merge(wire_params, extra_params(params))
  end

  defp extra_params(params) do
    case params["_meta"] do
      %{"arbor.acp.codex" => namespace} when is_map(namespace) ->
        Map.get(namespace, "params", %{})

      %{"arbor.acp.codex" => _} ->
        :invalid

      _ ->
        %{}
    end
  end

  def outbound(%{"method" => "_arbor/codex/status"}, state) do
    {:reply,
     %{
       "ready" => state.phase == :ready,
       "mode" => to_string(state.native_api),
       "error" => Map.get(state, :native_initialize_error)
     }, state}
  end

  def outbound(%{"method" => method, "params" => params} = msg, state)
      when method in [@request, @notify] do
    native_method = params["method"]
    native_params = Map.get(params, "params", %{})

    cond do
      method == @request and not Map.has_key?(msg, "id") ->
        {:error, :native_request_requires_id, state}

      method == @notify and Map.has_key?(msg, "id") ->
        {:error, :native_notification_must_not_have_id, state}

      not enabled?(state) ->
        {:error, :native_api_disabled, state}

      state.phase != :ready ->
        {:error, :native_not_ready, state}

      not is_binary(native_method) or native_method == "" ->
        {:error, :invalid_native_method, state}

      native_method in ["initialize", "initialized"] ->
        {:error, :native_handshake_owned_by_adapter, state}

      not json_object?(native_params) ->
        {:error, :invalid_native_params, state}

      method == @notify ->
        {:ok, Protocol.encode_notification(native_method, native_params), state}

      map_size(state.pending_requests) >= limit(state) ->
        {:error, :too_many_native_requests, state}

      true ->
        id = state.next_id
        entry = Protocol.request_entry(:native, msg["id"], %{})

        state = %{
          state
          | next_id: id + 1,
            pending_requests: Map.put(state.pending_requests, id, entry)
        }

        {:pending_and_write, Protocol.encode_request(id, native_method, native_params), state}
    end
  end

  def outbound(_msg, state), do: {:error, :unsupported_native_extension, state}

  def cancel(acp_id, state) do
    pending =
      Map.reject(state.pending_requests, fn {_id, entry} ->
        entry.type == :native and entry.acp_id == acp_id
      end)

    %{state | pending_requests: pending}
  end

  def server_request(id, method, params, state) do
    cond do
      Enum.any?(state.pending_client_requests, fn {_acp_id, entry} -> entry.codex_id == id end) ->
        {:skip_and_write,
         Protocol.encode_error(id, -32_600, "Native request id is already in use"), state}

      map_size(state.pending_client_requests) >= limit(state) ->
        {:skip_and_write, Protocol.encode_error(id, -32_000, "Too many native server requests"),
         state}

      true ->
        acp_id = "codex-native-#{state.next_id}"

        entry = %{
          kind: :native,
          codex_id: id,
          session_id: nil,
          thread_id: params["threadId"],
          turn_id: params["turnId"]
        }

        state = %{
          state
          | next_id: state.next_id + 1,
            pending_client_requests: Map.put(state.pending_client_requests, acp_id, entry)
        }

        {:messages,
         [Envelope.request(@request, %{"method" => method, "params" => params}, acp_id)], state}
    end
  end

  def resolved(_params, %{native_api: :off} = state), do: {[], state}

  def resolved(params, state) do
    id = params["requestId"] || params["id"]

    cancel_client_requests(state, fn entry -> entry.codex_id == id end)
  end

  def turn_completed(_params, %{native_api: :off} = state), do: {[], state}

  def turn_completed(params, state) do
    thread_id = params["threadId"]

    turn_id =
      case params["turn"] do
        %{"id" => id} -> id
        _ -> nil
      end

    # Codex can end an interrupted dynamic-tool call without a separate
    # serverRequest/resolved notification. Only settle explicitly scoped calls.
    if is_binary(thread_id) and is_binary(turn_id) do
      cancel_client_requests(state, fn entry ->
        entry.thread_id == thread_id and entry.turn_id == turn_id
      end)
    else
      {[], state}
    end
  end

  defp cancel_client_requests(state, predicate) do
    {cancelled, pending} =
      Enum.split_with(state.pending_client_requests, fn {_acp_id, entry} ->
        Map.get(entry, :kind) == :native and predicate.(entry)
      end)

    messages =
      Enum.map(cancelled, fn {acp_id, _} ->
        Envelope.notification("$/cancel_request", %{"requestId" => acp_id})
      end)

    {messages, %{state | pending_client_requests: Map.new(pending)}}
  end

  def response(entry, {:ok, result}, state),
    do: {:messages, [Envelope.response(entry.acp_id, %{"value" => result})], state}

  def response(entry, {:error, error}, state),
    do: {:messages, [Envelope.error(entry.acp_id, error)], state}

  def client_response(entry, response),
    do: Protocol.line(response |> Map.take(["result", "error"]) |> Map.put("id", entry.codex_id))

  defp add_request_frame({:messages, messages, state}, %{"id" => id, "method" => _} = event) do
    messages =
      Enum.map(messages, fn
        %{"method" => @request, "params" => params} = msg ->
          %{msg | "params" => params |> Map.put("requestId", id) |> Map.put("frame", event)}

        msg ->
          msg
      end)

    {:messages, messages, state}
  end

  defp add_request_frame(translated, _), do: translated

  def add_event(translated, event, state) do
    if enabled?(state) do
      translated = add_request_frame(translated, event)
      message = Envelope.notification(@event, %{"event" => event})

      case translated do
        {:skip, state} ->
          {:messages, [message], state}

        {:messages, messages, state} ->
          {:messages, messages ++ [message], state}

        {:skip_and_write, data, state} ->
          {:messages_and_write, [message], data, state}

        {:messages_and_write, messages, data, state} ->
          {:messages_and_write, messages ++ [message], data, state}

        other ->
          other
      end
    else
      translated
    end
  end
end
