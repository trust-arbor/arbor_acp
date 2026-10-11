defmodule Arbor.ACP.Adapters.Codex.Native do
  @moduledoc """
  Native Codex app-server access through an owned ArborACP connection.

  `start_link/1` starts an exclusive native connection. It uses the ACP
  transport runtime for process ownership, bounds and request correlation,
  while exposing native methods, parameters, results, errors and events.
  The adapter owns initialize/initialized; use `:native_initialize_params`
  in `:adapter_opts` to pass capability flags and future initialization fields.

  An existing Codex ACP connection may opt into `native_api: :shared` in
  `:adapter_opts`. Shared access is trusted application code: arbitrary native
  calls may change settings, threads or turns outside ACP's cached state and
  workspace authorization. The caller must coordinate those effects. Exclusive
  mode rejects ACP session operations and delegates every server request to
  the extension handler. In shared mode standard permissions/elicitation use
  ACP and unmapped requests use the extension handler.

  Server requests reach `c:Arbor.ACP.Client.Handler.handle_extension_request/3`
  with method `"_arbor/codex/request"` and params
  `%{"method" => native_method, "params" => native_params}`. Return the native
  JSON result or a complete JSON-RPC error object. Missing handlers fail closed.

  Native subscriptions receive
  `{:acp_extension_notification, "_arbor/codex/event", %{"event" => frame}}`.
  Frames retain all decoded fields, including unmapped notifications, responses
  and server requests. Capture begins after subscription admission; queues are
  bounded and an overflowing consumer closes the connection. No credentials
  or native frame payloads are logged by this API.

  `new_session/3`, `load_session/4`, `resume_session/4`, `prompt/4` and
  `prompt_text/4` accept `:native_params` on ordinary managed ACP connections,
  even when the raw API is off. Override maps use native string field names.
  Identity, input, workspace and permission fields remain owned by ACP and
  cannot be overridden. Other fields, including future ones, pass unchanged.
  Experimental fields require the corresponding native initialization flags.
  """

  alias Arbor.ACP.Client
  alias Arbor.ACP.Adapters.Codex.NativeProtocol

  @doc """
  Starts Codex and waits for its native handshake. Accepts ACP client options.

  `:native_mode` is `:exclusive` (default), `:shared`, or `:managed` (raw API off). CLI launch options and
  `:native_initialize_params` belong in `:adapter_opts`. The handshake wait is
  bounded by `:initialize_timeout` (30 seconds by default).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    mode = Keyword.get(opts, :native_mode, :exclusive)

    unless mode in [:exclusive, :shared, :managed],
      do: raise(ArgumentError, "native_mode must be :exclusive, :shared, or :managed")

    adapter_opts =
      opts
      |> Keyword.get(:adapter_opts, [])
      |> Keyword.put(:native_api, if(mode == :managed, do: :off, else: mode))

    opts =
      opts
      |> Keyword.delete(:native_mode)
      |> Keyword.put(:adapter_opts, adapter_opts)
      |> Keyword.put(:transport_mod, Arbor.ACP.AdapterTransport)
      |> Keyword.put(:adapter, Arbor.ACP.Adapters.Codex)

    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :initialize_timeout, 30_000)

    with {:ok, client} <- Client.start_link(opts) do
      case await_ready(client, deadline) do
        :ok ->
          {:ok, client}

        {:error, reason} ->
          case Client.stop(client) do
            :ok -> {:error, reason}
            {:error, cleanup} -> {:error, {:cleanup_failed, reason, cleanup}}
          end
      end
    end
  end

  @doc "Returns an OTP child specification for a native connection."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Calls any native RPC method and returns its unchanged result or error object."
  @spec request(GenServer.server(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def request(client, method, params \\ %{}, opts \\ []) do
    case Client.extension_request(
           client,
           "_arbor/codex/request",
           %{"method" => method, "params" => params},
           opts
         ) do
      {:ok, %{"value" => result}} -> {:ok, result}
      other -> other
    end
  end

  @doc "Sends a native notification; success confirms transport admission only."
  @spec notify(GenServer.server(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def notify(client, method, params \\ %{}, opts \\ []),
    do:
      Client.extension_notify(
        client,
        "_arbor/codex/notify",
        %{"method" => method, "params" => params},
        opts
      )

  @doc "Subscribes to all decoded native frames using the bounded ACP extension subscription."
  @spec subscribe(GenServer.server(), pid(), keyword()) :: :ok | {:error, term()}
  def subscribe(client, pid \\ self(), opts \\ []) do
    case Client.extension_request(client, "_arbor/codex/status", %{}, opts) do
      {:ok, %{"mode" => "off"}} ->
        {:error, :native_api_disabled}

      {:ok, _status} ->
        Client.subscribe_extensions(
          client,
          pid,
          Keyword.put(opts, :methods, ["_arbor/codex/event"])
        )

      {:error, _} = error ->
        error
    end
  end

  @doc "Removes this PID's extension subscription."
  @spec unsubscribe(GenServer.server(), pid(), keyword()) :: :ok | {:error, term()}
  def unsubscribe(client, pid \\ self(), opts \\ []),
    do: Client.unsubscribe_extensions(client, pid, opts)

  @doc "Creates an ACP session with additional native thread/start parameters."
  @spec new_session(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def new_session(client, cwd, opts \\ []), do: Client.new_session(client, cwd, native_opts(opts))

  @doc "Loads an ACP session with additional native thread/resume parameters."
  @spec load_session(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def load_session(client, session, cwd, opts \\ []),
    do: Client.load_session(client, session, cwd, native_opts(opts))

  @doc "Resumes an ACP session with additional native thread/resume parameters."
  @spec resume_session(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def resume_session(client, session, cwd, opts \\ []),
    do: Client.resume_session(client, session, cwd, native_opts(opts))

  @doc "Prompts through ACP with additional native turn/start parameters, retaining ACP streaming."
  @spec prompt(GenServer.server(), String.t(), String.t() | [map()], keyword()) ::
          {:ok, term()} | {:error, term()}
  def prompt(client, session, content, opts \\ []),
    do: Client.prompt(client, session, content, native_opts(opts))

  @doc "Collects bounded ACP prompt text with additional native turn/start parameters."
  @spec prompt_text(GenServer.server(), String.t(), String.t() | [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def prompt_text(client, session, content, opts \\ []),
    do: Client.prompt_text(client, session, content, native_opts(opts))

  defp native_opts(opts) do
    {params, opts} = Keyword.pop(opts, :native_params, %{})
    meta = Keyword.get(opts, :meta, %{})

    unless NativeProtocol.json_object?(params) and NativeProtocol.json_object?(meta),
      do: raise(ArgumentError, "native_params and meta must be JSON objects with string keys")

    namespace = Map.get(meta, "arbor.acp.codex", %{})

    unless is_map(namespace),
      do: raise(ArgumentError, "arbor.acp.codex metadata must be an object")

    Keyword.put(
      opts,
      :meta,
      Map.put(meta, "arbor.acp.codex", Map.put(namespace, "params", params))
    )
  end

  defp await_ready(client, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :native_initialize_timeout}
    else
      case Client.extension_request(client, "_arbor/codex/status", %{},
             timeout: min(remaining, 1000)
           ) do
        {:ok, %{"error" => error}} when not is_nil(error) ->
          {:error, {:native_initialize_failed, error}}

        {:ok, %{"ready" => true}} ->
          :ok

        {:ok, _} ->
          Process.sleep(min(10, remaining))
          await_ready(client, deadline)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
