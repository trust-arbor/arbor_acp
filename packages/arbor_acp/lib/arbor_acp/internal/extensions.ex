defmodule Arbor.ACP.Internal.Extensions do
  @moduledoc false

  alias Arbor.RPC.JSONRPC

  def validate("_" <> suffix, params) when suffix != "" and is_map(params) do
    if String.valid?("_" <> suffix) and json?(params),
      do: :ok,
      else: {:error, :invalid_extension_params}
  end

  def validate(_method, _params), do: {:error, :invalid_extension_method_or_params}

  def validate_request(method, params)
      when is_binary(method) and method != "" and is_map(params) do
    if String.valid?(method) and json?(params),
      do: :ok,
      else: {:error, :invalid_request_params}
  end

  def validate_request(_method, _params), do: {:error, :invalid_request_method_or_params}

  def json?(value) when is_binary(value), do: String.valid?(value)
  def json?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  def json?(value) when is_list(value), do: Enum.all?(value, &json?/1)
  def json?(%{__struct__: _}), do: false

  def json?(value) when is_map(value),
    do: Enum.all?(value, fn {k, v} -> is_binary(k) and String.valid?(k) and json?(v) end)

  def json?(_value), do: false

  def request(method, params),
    do: JSONRPC.request(method, params, System.unique_integer([:positive, :monotonic]))

  def notification(method, params), do: JSONRPC.notification(method, params)

  def room?(pid, incoming, count_limit, byte_limit) do
    with {:message_queue_len, count} when count < count_limit <-
           Process.info(pid, :message_queue_len),
         {:messages, messages} when length(messages) < count_limit <- Process.info(pid, :messages) do
      bytes =
        Enum.reduce_while(messages, 0, fn message, total ->
          total = total + :erlang.external_size(message)
          if total + incoming > byte_limit, do: {:halt, total}, else: {:cont, total}
        end)

      bytes + incoming <= byte_limit
    else
      _ -> false
    end
  end

  def error?(%{"code" => code, "message" => message} = error),
    do: is_integer(code) and is_binary(message) and json?(error)

  def error?(_), do: false
end
