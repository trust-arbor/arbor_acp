defmodule Arbor.ACP.Client do
  @moduledoc """
  GenServer client for the Agent Client Protocol (ACP).

  Manages connections to ACP-compatible coding agents over stdio, handling
  the initialize handshake, session lifecycle, and bidirectional communication
  (streaming updates from agent, permission/file requests from agent).

  ## Usage

      {:ok, client} = Arbor.ACP.Client.start_link(
        command: ["gemini", "--acp"],
        handler: MyApp.ACPHandler
      )

      {:ok, %{"sessionId" => sid}} = Arbor.ACP.Client.new_session(client, "/path/to/project")
      {:ok, %{"stopReason" => _}} = Arbor.ACP.Client.prompt(client, sid, "Fix the bug in auth.ex")

  ## Options

  - `:command` — command list for the agent subprocess (required)
  - `:handler` — module implementing `Arbor.ACP.Client.Handler` (default: `DefaultHandler`)
  - `:handler_opts` — options passed to `handler.init/1` (default: `[]`)
  - `:event_listener` — PID to receive `{:acp_session_update, session_id, update}` messages
  - `:client_info` — `%{"name" => ..., "version" => ...}` (default: `%{"name" => "ex_mcp", "version" => "0.1.0"}`)
  - `:capabilities` — client capabilities map
  - `:protocol_version` — integer (default: 1)
  - `:initialize_timeout` — total initialize-handshake timeout in milliseconds
    (default: 30_000)
  - `:max_frame_bytes` — maximum inbound or outbound JSON-RPC frame size
    (default: 1 MiB)
  - `:max_pending_requests` — maximum concurrent requests in either direction
    (default: 1,024)
  - `:max_prompt_text_bytes` — maximum streamed prompt text retained per session
    (default: 1 MiB)
  - `:pending_request_timeout` — server-side lifetime for outbound requests
    (default: 30_000 ms)
  - `:handler_request_timeout` — lifetime for inbound client-handler callbacks
    (default: 30_000 ms)
  - `:max_update_queue` — mailbox cutoff for handler/listener session updates;
    excess updates are dropped (default: 32)
  - `:max_update_queue_bytes` — aggregate encoded size cutoff for queued
    handler/listener session updates (default: 8 MiB)
  - `:name` — GenServer name registration
  - `:mcp_providers` — UNSTABLE map of MCP `serverId` to `:handler`, a
    `Arbor.ACP.Client.McpProvider` module, or a local pid. See
    `docs/MCP_OVER_ACP.md`.
  """

  use GenServer

  require Logger

  alias Arbor.ACP.Internal.Extensions
  alias Arbor.ACP.Capabilities
  alias Arbor.ACP.LifecycleParams
  alias Arbor.ACP.Maps
  alias Arbor.ACP.PendingRequests
  alias Arbor.ACP.RequestValidation
  alias Arbor.ACP.Client.ConnectionScope
  alias Arbor.ACP.Client.DefaultHandler
  alias Arbor.ACP.Client.HandlerRunner
  alias Arbor.ACP.Protocol
  alias Arbor.RPC.LogSummary
  alias Arbor.ACP.Internal.{Call, Mcp, Options}
  alias Arbor.ACP.AdapterSupport.WorkspacePath
  alias Arbor.ACP.Transport.Stdio

  @default_initialize_timeout 30_000
  @maximum_initialize_timeout 4_294_967_295
  @default_max_frame_bytes 1_048_576
  @default_max_pending_requests 1_024
  @default_max_prompt_text_bytes 1_048_576
  @default_pending_request_timeout 30_000
  @default_handler_request_timeout 30_000
  @default_max_update_queue 32
  @default_max_update_queue_bytes 8_388_608
  @supported_protocol_versions [1]

  defstruct [
    :connection_scope,
    :scope_monitor,
    :transport_mod,
    :transport_state,
    :receiver_pid,
    :transport_actor_monitor,
    :agent_info,
    :agent_capabilities,
    :initialize_result,
    :client_capabilities,
    :auth_methods,
    :handler_mod,
    :handler_pid,
    :event_listener,
    :protocol_version,
    max_frame_bytes: @default_max_frame_bytes,
    max_pending_requests: @default_max_pending_requests,
    max_prompt_text_bytes: @default_max_prompt_text_bytes,
    pending_request_timeout: @default_pending_request_timeout,
    handler_request_timeout: @default_handler_request_timeout,
    max_update_queue: @default_max_update_queue,
    max_update_queue_bytes: @default_max_update_queue_bytes,
    extension_subscribers: %{},
    pending_requests: %{},
    pending_caller_monitors: %{},
    pending_agent_requests: %{},
    sessions: %{},
    # Only explicit prompt_text calls retain bounded streamed message text.
    prompt_text: %{},
    cleanup_result: :ok,
    status: :connecting,
    mcp: %Arbor.ACP.Internal.Mcp{},
    mcp_providers: %{},
    mcp_provider_monitors: %{},
    mcp_plans: %{}
  ]

  # Public API

  @doc """
  Calls an underscore-prefixed ACP extension using ordinary request ownership.

  Parameters must be a JSON object with string keys. Results and peer error
  objects are preserved. Extensions have application-defined authority and
  semantics; check advertised `_meta` capabilities before calling them.
  A timeout does not prove that the remote operation stopped.
  """
  @spec extension_request(GenServer.server(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def extension_request(client, method, params, opts \\ []) do
    with :ok <- Extensions.validate(method, params) do
      Call.call(
        client,
        {:extension_request, Extensions.request(method, params)},
        Call.timeout!(opts, 30_000)
      )
    end
  end

  @doc "Sends an underscore-prefixed notification; success confirms transport admission only."
  @spec extension_notify(GenServer.server(), String.t(), map(), keyword()) ::
          :ok | {:error, term()}
  def extension_notify(client, method, params, opts \\ []) do
    with :ok <- Extensions.validate(method, params) do
      Call.call(
        client,
        {:extension_notify, Extensions.notification(method, params)},
        Call.timeout!(opts)
      )
    end
  end

  @doc """
  Subscribes a PID to extension notifications as
  `{:acp_extension_notification, method, params}`. `:methods` is `:all` or a
  list of underscore-prefixed method names. There are at most 32 subscribers.
  Subscribers are monitored. The existing update queue count/byte limits
  apply; a full consumer queue closes the connection instead of silently
  losing extension events. Notifications also reach the optional handler.
  """
  @spec subscribe_extensions(GenServer.server(), pid(), keyword()) :: :ok | {:error, term()}
  def subscribe_extensions(client, pid \\ self(), opts \\ []) do
    Call.call(
      client,
      {:subscribe_extensions, pid, Keyword.get(opts, :methods, :all)},
      Call.timeout!(opts)
    )
  end

  @doc "Removes an extension notification subscription."
  @spec unsubscribe_extensions(GenServer.server(), pid(), keyword()) :: :ok | {:error, term()}
  def unsubscribe_extensions(client, pid \\ self(), opts \\ []),
    do: Call.call(client, {:unsubscribe_extensions, pid}, Call.timeout!(opts))

  @doc "Starts the ACP client and connects to the agent."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, client_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, client_opts, gen_opts)
  end

  @doc """
  Opens an initialized client for the callback and closes its owned resources.

  Accepts the same connection options as `start_link/1`. The callback runs in
  the calling process. Success returns `{:ok, value}` after cleanup; failure
  returns `{:error, {:cleanup_failed, reason, value}}`, retaining its value.
  Callback exceptions/exits/throws are raised again after bounded cleanup.
  A private guardian also closes the client if the calling process exits.

  `with_connection/3` accepts positive finite `:establish_timeout` (30_000 ms)
  and `:cleanup_timeout` (5_000 ms). Startup has one cutoff covering handler
  initialization, transport construction and protocol negotiation. Cleanup has
  its own single cutoff; timeouts remain errors and do not prove physical IO
  cleanup. Client, handler and receiver processes register before their work.
  Native stdio cleanup uses ArborRPC receipts. Custom transport `close/1`
  controls external cleanup; unregistered custom effects are outside the scope.
  Names must be local atoms; existing clients cannot be adopted into this scope.

      Client.with_connection([command: ["my-agent", "--acp"]], fn client ->
        Client.new_session(client, "/path/to/project")
      end)
  """
  @spec with_connection(keyword(), (GenServer.server() -> value)) ::
          {:ok, value} | {:error, term()}
        when value: term()
  def with_connection(client_opts, callback), do: with_connection(client_opts, [], callback)

  @spec with_connection(keyword(), keyword(), (GenServer.server() -> value)) ::
          {:ok, value} | {:error, term()}
        when value: term()
  def with_connection(client_opts, scope_opts, callback),
    do: ConnectionScope.run(client_opts, scope_opts, callback)

  @doc """
  Authenticates with the agent.

  Pass either a method ID advertised in the initialize response's
  `"authMethods"` list or a full params map for adapter compatibility.
  """
  @spec authenticate(GenServer.server(), String.t() | map(), keyword()) ::
          {:ok, map() | nil} | {:error, any()}
  def authenticate(client, method_id_or_params \\ %{}, opts \\ []) do
    timeout = Call.timeout!(opts, 30_000)
    Call.call(client, {:authenticate, method_id_or_params}, timeout)
  end

  @doc "Logs out of the current authenticated state if the agent supports `auth.logout`."
  @spec logout(GenServer.server(), keyword()) :: {:ok, map() | nil} | {:error, any()}
  def logout(client, opts \\ []) do
    timeout = Call.timeout!(opts, 30_000)
    Call.call(client, :logout, timeout)
  end

  @doc """
  Creates a new agent session.

  `:meta` carries a JSON metadata object in the standard ACP `_meta` field.
  `cwd` is required per ACP spec
  (https://agentclientprotocol.com/protocol/session-setup).
  """
  @spec new_session(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, any()}
  def new_session(client, cwd, opts \\ []) when is_binary(cwd) do
    timeout = Call.timeout!(opts, 30_000)
    Call.call(client, {:new_session, cwd, LifecycleParams.client_opts(opts)}, timeout)
  end

  @doc """
  Loads an existing session and replays previous messages when the agent supports it.

  `cwd` is required per ACP spec.
  """
  @spec load_session(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, any()}
  def load_session(client, session_id, cwd, opts \\ []) when is_binary(cwd) do
    timeout = Call.timeout!(opts, 30_000)

    Call.call(
      client,
      {:load_session, session_id, cwd, LifecycleParams.client_opts(opts)},
      timeout
    )
  end

  @doc """
  Resumes an existing session without replaying previous messages.

  `cwd` is required per ACP spec.
  """
  @spec resume_session(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, any()}
  def resume_session(client, session_id, cwd, opts \\ []) when is_binary(cwd) do
    timeout = Call.timeout!(opts, 30_000)

    Call.call(
      client,
      {:resume_session, session_id, cwd, LifecycleParams.client_opts(opts)},
      timeout
    )
  end

  @doc """
  Forks an existing session into a new independent session.

  `session/fork` is currently unstable in ACP and requires the agent to
  advertise `sessionCapabilities.fork`.
  """
  @spec fork_session(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, any()}
  def fork_session(client, session_id, cwd, opts \\ []) when is_binary(cwd) do
    timeout = Call.timeout!(opts, 30_000)

    Call.call(
      client,
      {:fork_session, session_id, cwd, LifecycleParams.client_opts(opts)},
      timeout
    )
  end

  @doc """
  Sends a prompt to the agent and blocks until the response arrives.

  Streaming `session/update` notifications are delivered to the handler and
  event listener as they arrive. The caller is unblocked when the agent sends
  the JSON-RPC result for the prompt request.

  `:meta` carries standard ACP request metadata.
  Returns the agent's result unchanged, including completion metadata and
  extensions. Use `prompt_text/4` to explicitly collect streamed message text.
  """
  @spec prompt(GenServer.server(), String.t(), String.t() | [map()], keyword()) ::
          {:ok, Arbor.ACP.Types.json_value()} | {:error, term()}
  def prompt(client, session_id, content, opts \\ []) do
    timeout = Call.timeout!(opts, 300_000)
    Call.call(client, {:prompt, session_id, content, Keyword.get(opts, :meta)}, timeout)
  end

  @doc """
  Sends a prompt and collects streamed agent message text within a byte limit.

  Returns `{:ok, %{result: result, text: text, truncated?: boolean}}`. `result`
  is the unchanged peer result; `text` is a UTF-8 prefix of text blocks from
  `agent_message_chunk` updates only. Thought chunks, nontext content and peer
  extension fields are not folded into it. Streaming callbacks still run.

  `:timeout` defaults to 300_000 ms. `:max_text_bytes` may lower the client's
  `:max_prompt_text_bytes` limit (default 1 MiB); it must be positive. Collection
  stops at the first truncated chunk and reports `truncated?: true`.
  A collecting prompt cannot overlap another prompt in the same session;
  conflicting calls return `{:error, :prompt_in_progress}` before sending.
  Protocol/transport failures retain the ordinary `{:error, reason}` result.
  """
  @spec prompt_text(GenServer.server(), String.t(), String.t() | [map()], keyword()) ::
          {:ok, %{result: map(), text: String.t(), truncated?: boolean()}} | {:error, term()}
  def prompt_text(client, session_id, content, opts \\ []) do
    opts = Keyword.validate!(opts, [:timeout, :max_text_bytes, :meta])
    limit = Keyword.get(opts, :max_text_bytes)

    unless is_nil(limit) or (is_integer(limit) and limit > 0),
      do: raise(ArgumentError, "max_text_bytes must be a positive byte count")

    Call.call(
      client,
      {:prompt_text, session_id, content, limit, Keyword.get(opts, :meta)},
      Call.timeout!(opts, 300_000)
    )
  end

  @doc "Lists available sessions from the agent. Stabilized in ACP spec March 9, 2026."
  @spec list_sessions(GenServer.server(), keyword()) :: {:ok, map()} | {:error, any()}
  def list_sessions(client, opts \\ []) do
    timeout = Call.timeout!(opts, 30_000)
    Call.call(client, {:list_sessions, opts}, timeout)
  end

  @doc "Queues cancellation of the current prompt; :ok does not confirm remote cancellation."
  @spec cancel(GenServer.server(), String.t()) :: :ok
  def cancel(client, session_id) do
    GenServer.cast(client, {:cancel, session_id})
  end

  @doc "Queues a `$/cancel_request` notification; :ok does not confirm delivery."
  @spec cancel_request(GenServer.server(), integer() | String.t() | nil) :: :ok
  def cancel_request(client, request_id) do
    GenServer.cast(client, {:cancel_request, request_id})
  end

  @doc "Closes an active session and frees agent-side resources."
  @spec close_session(GenServer.server(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, any()}
  def close_session(client, session_id, opts \\ []) do
    timeout = Call.timeout!(opts, 30_000)
    Call.call(client, {:close_session, session_id}, timeout)
  end

  @doc "Deletes a session from the agent's session history."
  @spec delete_session(GenServer.server(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, any()}
  def delete_session(client, session_id, opts \\ []) do
    timeout = Call.timeout!(opts, 30_000)
    Call.call(client, {:delete_session, session_id}, timeout)
  end

  @doc "Sets the agent mode for a session."
  @spec set_mode(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, any()}
  def set_mode(client, session_id, mode_id, opts \\ []) do
    timeout = opts |> Keyword.validate!([:timeout]) |> Call.timeout!(30_000)
    Call.call(client, {:set_mode, session_id, mode_id}, timeout)
  end

  @doc "Sets the model for a session."
  @spec set_model(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, any()}
  def set_model(client, session_id, model_id, opts \\ []) do
    timeout = opts |> Keyword.validate!([:timeout]) |> Call.timeout!(30_000)
    Call.call(client, {:set_model, session_id, model_id}, timeout)
  end

  @doc "Sets a config option for a session."
  @spec set_config_option(GenServer.server(), String.t(), String.t(), any(), keyword()) ::
          {:ok, map()} | {:error, any()}
  def set_config_option(client, session_id, config_id, value, opts \\ []) do
    timeout = opts |> Keyword.validate!([:timeout]) |> Call.timeout!(30_000)
    Call.call(client, {:set_config_option, session_id, config_id, value}, timeout)
  end

  @doc "Returns the agent's capabilities from the initialize handshake."
  @spec agent_capabilities(GenServer.server()) :: {:ok, map() | nil} | {:error, term()}
  def agent_capabilities(client) do
    Call.call(client, :agent_capabilities)
  end

  @doc """
  Returns the complete initialize result, including `_meta` and any fields the
  typed accessors do not cover, or `nil` before the handshake completed.
  """
  @spec initialize_result(GenServer.server()) :: {:ok, map() | nil} | {:error, term()}
  def initialize_result(client) do
    Call.call(client, :initialize_result)
  end

  @doc """
  Returns the agent's `_meta` object from the initialize handshake, or `nil`
  when the agent omitted it. Agents advertise extension capabilities here;
  check it before calling `extension_request/4`.
  """
  @spec agent_meta(GenServer.server()) :: {:ok, map() | nil} | {:error, term()}
  def agent_meta(client) do
    Call.call(client, :agent_meta)
  end

  @doc "Returns the agent's authentication methods from the initialize handshake."
  @spec auth_methods(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def auth_methods(client) do
    Call.call(client, :auth_methods)
  end

  @doc "Returns the client connection status."
  @spec status(GenServer.server(), keyword()) :: {:ok, atom()} | {:error, term()}
  def status(client, opts \\ []), do: Call.status(client, opts)

  @doc "Returns connection status, raising if the client is unavailable."
  @spec status!(GenServer.server(), keyword()) :: atom()
  def status!(client, opts \\ []), do: client |> status(opts) |> Call.unwrap!()

  @doc """
  Ends a session.

  Uses `session/close` when advertised by the agent, otherwise preserves the
  historical local telemetry-only behavior.
  """
  @spec end_session(GenServer.server(), String.t()) ::
          :ok | {:ok, map() | nil} | {:error, any()}
  def end_session(client, session_id) do
    Call.call(client, {:end_session, session_id})
  end

  @doc """
  Disconnects the transport and settles pending requests, retaining the client process.

  An in-flight module or `:handler` MCP provider is stopped. A pid provider
  stays the caller's process.
  """
  @spec disconnect(GenServer.server()) :: :ok | {:error, term()}
  def disconnect(client) do
    Call.call(client, :disconnect)
  end

  @doc """
  Stops this client after transport cleanup and waits for its process to exit.

  One finite `:timeout` (default 5_000 ms) covers cleanup and process termination.
  Already-stopped clients return `:ok`. Cleanup failure or timeout remains an
  error; process death does not prove physical IO cleanup. Caller timeout does
  not kill unrelated processes or extend the transport's own cleanup budget.
  A supervisor still applies its child restart policy.
  """
  @spec stop(GenServer.server(), term(), keyword()) :: :ok | {:error, term()}
  def stop(client, reason \\ :normal, opts \\ []), do: Call.stop(client, reason, opts)

  @doc """
  UNSTABLE. Registers the MCP provider for one `serverId`.

  The provider is `:handler`, a module implementing `Arbor.ACP.Client.McpProvider`,
  or a live local pid. A server id reserved for a session that is opening, or
  bound to a live session, cannot be registered or replaced and returns
  `{:error, :mcp_server_id_in_use}`. The design note is `docs/MCP_OVER_ACP.md`.
  """
  @spec register_mcp_provider(GenServer.server(), String.t(), term(), keyword()) ::
          :ok | {:error, term()}
  def register_mcp_provider(client, server_id, provider, opts \\ [])
      when is_binary(server_id) do
    Call.call(client, {:register_mcp_provider, server_id, provider}, Call.timeout!(opts))
  end

  @doc """
  UNSTABLE. Drops the provider for `serverId` when no live or pending session
  owns that id. The design note is `docs/MCP_OVER_ACP.md`.
  """
  @spec unregister_mcp_provider(GenServer.server(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def unregister_mcp_provider(client, server_id, opts \\ []) when is_binary(server_id) do
    Call.call(client, {:unregister_mcp_provider, server_id}, Call.timeout!(opts))
  end

  @doc """
  UNSTABLE. Sends an `mcp/message` notification for one in-flight MCP request.

  `:token` is the reference from the provider context. The notification is
  sent only when that token still identifies the active request. A missing
  token, a finished or cancelled request, or a token from another session
  returns `{:error, :unknown_mcp_request}`.

  `:session_id`, when set, must be the session that owns the request.
  `:params` and `:meta` are string-keyed JSON objects or `nil`. Calling this
  from the client process raises `ArgumentError`. The design note is
  `docs/MCP_OVER_ACP.md`.
  """
  @spec mcp_notify(GenServer.server(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def mcp_notify(client, server_id, request_id, method, opts \\ [])
      when is_binary(server_id) and is_binary(request_id) and is_binary(method) do
    if client == self() do
      raise ArgumentError, "mcp_notify/5 cannot be called from the client process"
    end

    opts = Keyword.validate!(opts, [:params, :meta, :timeout, :token, :session_id])

    with :ok <- json_object_option(Keyword.get(opts, :params)),
         :ok <- json_object_option(Keyword.get(opts, :meta)),
         :ok <- notify_token(Keyword.get(opts, :token)),
         :ok <- notify_session(Keyword.get(opts, :session_id)) do
      Call.call(
        client,
        {:mcp_notify, server_id, request_id, method, Keyword.get(opts, :params),
         Keyword.get(opts, :meta), Keyword.get(opts, :token), Keyword.get(opts, :session_id)},
        Call.timeout!(opts)
      )
    end
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    scope = Keyword.get(opts, :_connection_scope)

    case ConnectionScope.register(scope, :client) do
      :ok -> init_client(opts, scope, ConnectionScope.monitor(scope))
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:new_session, cwd, lifecycle_opts}, from, %{status: :ready} = state) do
    with :ok <- LifecycleParams.validate_cwd(cwd),
         :ok <- LifecycleParams.validate(lifecycle_opts, state.agent_capabilities) do
      open_mcp_session(
        &Protocol.encode_session_new(cwd, &1),
        from,
        state,
        {:new_session, session_roots(cwd, lifecycle_opts)},
        lifecycle_opts,
        :new
      )
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:authenticate, method_id_or_params}, from, %{status: :ready} = state) do
    msg = Protocol.encode_authenticate(method_id_or_params)
    send_request(msg, from, state)
  end

  def handle_call(:logout, from, %{status: :ready} = state) do
    case ensure_capability(state, :logout) do
      :ok ->
        msg = Protocol.encode_logout()
        send_request(msg, from, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list_sessions, opts}, from, %{status: :ready} = state) do
    case ensure_capability(state, :session_list) do
      :ok ->
        msg = Protocol.encode_session_list(opts)
        send_request(msg, from, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:load_session, session_id, cwd, lifecycle_opts},
        from,
        %{status: :ready} = state
      ) do
    case ensure_capability(state, :load_session) do
      :ok ->
        with :ok <- LifecycleParams.validate_cwd(cwd),
             :ok <- LifecycleParams.validate(lifecycle_opts, state.agent_capabilities) do
          open_mcp_session(
            &Protocol.encode_session_load(session_id, cwd, &1),
            from,
            state,
            {:load_session, session_id, session_roots(cwd, lifecycle_opts)},
            lifecycle_opts,
            {:existing, session_id}
          )
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:resume_session, session_id, cwd, lifecycle_opts},
        from,
        %{status: :ready} = state
      ) do
    case ensure_capability(state, :session_resume) do
      :ok ->
        with :ok <- LifecycleParams.validate_cwd(cwd),
             :ok <- LifecycleParams.validate(lifecycle_opts, state.agent_capabilities) do
          open_mcp_session(
            &Protocol.encode_session_resume(session_id, cwd, &1),
            from,
            state,
            {:resume_session, session_id, session_roots(cwd, lifecycle_opts)},
            lifecycle_opts,
            {:existing, session_id}
          )
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:fork_session, session_id, cwd, lifecycle_opts},
        from,
        %{status: :ready} = state
      ) do
    case ensure_capability(state, :session_fork) do
      :ok ->
        with :ok <- LifecycleParams.validate_cwd(cwd),
             :ok <- LifecycleParams.validate(lifecycle_opts, state.agent_capabilities) do
          open_mcp_session(
            &Protocol.encode_session_fork(session_id, cwd, &1),
            from,
            state,
            {:fork_session, session_roots(cwd, lifecycle_opts)},
            lifecycle_opts,
            :new
          )
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:extension_request, msg}, from, %{status: :ready} = state),
    do: send_request(msg, from, state)

  def handle_call({:extension_notify, msg}, _from, %{status: :ready} = state) do
    case do_send(msg, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe_extensions, pid, methods}, _from, state) do
    valid_methods =
      methods == :all or
        (is_list(methods) and Enum.all?(methods, &(Extensions.validate(&1, %{}) == :ok)))

    cond do
      not is_pid(pid) or node(pid) != node() or not Process.alive?(pid) or not valid_methods ->
        {:reply, {:error, :invalid_subscription}, state}

      not Map.has_key?(state.extension_subscribers, pid) and
          map_size(state.extension_subscribers) >= 32 ->
        {:reply, {:error, :too_many_subscribers}, state}

      true ->
        existing = Map.get(state.extension_subscribers, pid)
        monitor = if existing, do: existing.monitor, else: Process.monitor(pid)

        subscribers =
          Map.put(state.extension_subscribers, pid, %{monitor: monitor, methods: methods})

        {:reply, :ok, %{state | extension_subscribers: subscribers}}
    end
  end

  def handle_call({:unsubscribe_extensions, pid}, _from, state) do
    {subscription, subscribers} = Map.pop(state.extension_subscribers, pid)
    if subscription, do: Process.demonitor(subscription.monitor, [:flush])
    {:reply, :ok, %{state | extension_subscribers: subscribers}}
  end

  def handle_call({:prompt, session_id, content, meta}, from, %{status: :ready} = state) do
    start_prompt(session_id, content, :raw, from, state, meta)
  end

  def handle_call(
        {:prompt_text, session_id, content, limit, meta},
        from,
        %{status: :ready} = state
      ) do
    start_prompt(session_id, content, {:collect, limit}, from, state, meta)
  end

  def handle_call({:prompt, session_id, content}, from, %{status: :ready} = state) do
    start_prompt(session_id, content, :raw, from, state)
  end

  def handle_call({:prompt_text, session_id, content, limit}, from, %{status: :ready} = state) do
    start_prompt(session_id, content, {:collect, limit}, from, state)
  end

  def handle_call({:set_mode, session_id, mode_id}, from, %{status: :ready} = state) do
    msg = Protocol.encode_session_set_mode(session_id, mode_id)
    send_request(msg, from, state)
  end

  def handle_call({:set_model, session_id, model_id}, from, %{status: :ready} = state) do
    msg = Protocol.encode_session_set_model(session_id, model_id)
    send_request(msg, from, state)
  end

  def handle_call(
        {:set_config_option, session_id, config_id, value},
        from,
        %{status: :ready} = state
      ) do
    msg = Protocol.encode_session_set_config_option(session_id, config_id, value)
    send_request(msg, from, state)
  end

  def handle_call(:agent_capabilities, _from, state) do
    {:reply, {:ok, state.agent_capabilities}, state}
  end

  def handle_call(:initialize_result, _from, state) do
    {:reply, {:ok, state.initialize_result}, state}
  end

  def handle_call(:agent_meta, _from, state) do
    meta =
      case state.initialize_result do
        %{"_meta" => meta} when is_map(meta) -> meta
        _missing -> nil
      end

    {:reply, {:ok, meta}, state}
  end

  def handle_call(:auth_methods, _from, state) do
    {:reply, {:ok, state.auth_methods || []}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call({:close_session, session_id}, from, %{status: :ready} = state) do
    case ensure_capability(state, :session_close) do
      :ok ->
        msg = Protocol.encode_session_close(session_id)
        send_request(msg, from, state, {:close_session, session_id})

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_session, session_id}, from, %{status: :ready} = state) do
    case ensure_capability(state, :session_delete) do
      :ok ->
        msg = Protocol.encode_session_delete(session_id)
        send_request(msg, from, state, {:delete_session, session_id})

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:end_session, session_id}, from, %{status: :ready} = state) do
    case ensure_capability(state, :session_close) do
      :ok ->
        msg = Protocol.encode_session_close(session_id)
        send_request(msg, from, state, {:close_session, session_id})

      {:error, {:unsupported_capability, :session_close}} ->
        emit_session_ended(session_id)
        state = %{state | sessions: Map.delete(state.sessions, session_id)}
        {:reply, :ok, release_mcp_session(state, session_id)}
    end
  end

  def handle_call({:stop, reason}, _from, state) do
    state = do_disconnect(state)
    {:stop, reason, {:stopping, state.cleanup_result, state.handler_pid}, state}
  end

  def handle_call(:disconnect, _from, state) do
    state = do_disconnect(state)
    {:reply, state.cleanup_result, state}
  end

  def handle_call({:register_mcp_provider, server_id, provider}, _from, state) do
    cond do
      not valid_server_id?(server_id) ->
        {:reply, {:error, :invalid_params}, state}

      mcp_server_in_use?(state, server_id) ->
        {:reply, {:error, :mcp_server_id_in_use}, state}

      true ->
        case normalize_provider(provider) do
          {:ok, provider} ->
            state = state |> drop_provider_monitor(server_id) |> put_provider(server_id, provider)
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:unregister_mcp_provider, server_id}, _from, state) do
    cond do
      not valid_server_id?(server_id) ->
        {:reply, {:error, :invalid_params}, state}

      mcp_server_in_use?(state, server_id) ->
        {:reply, {:error, :mcp_server_id_in_use}, state}

      true ->
        state = drop_provider_monitor(state, server_id)
        {:reply, :ok, %{state | mcp_providers: Map.delete(state.mcp_providers, server_id)}}
    end
  end

  def handle_call(
        {:mcp_notify, server_id, request_id, method, params, meta, token, session_id},
        _from,
        state
      ) do
    case Mcp.lookup(state.mcp, server_id, request_id) do
      %{token: ^token, session_id: owner} when is_reference(token) ->
        if session_id == nil or session_id == owner do
          message =
            Protocol.encode_mcp_message_notification(server_id, request_id, method,
              params: params,
              meta: meta
            )

          case do_send(message, state) do
            {:ok, state} -> {:reply, :ok, state}
            {:error, reason} -> {:reply, {:error, reason}, state}
          end
        else
          {:reply, {:error, :unknown_mcp_request}, state}
        end

      _missing_or_stale ->
        {:reply, {:error, :unknown_mcp_request}, state}
    end
  end

  # A provider task asks this immediately before it enters. The session must
  # still be open and this request must still be pending, so a callback that
  # was only queued does not run after close or cancellation.
  def handle_call({:mcp_provider_admitted, ref, session_id}, _from, state) do
    request = Map.get(state.pending_agent_requests, ref)

    admitted? =
      match?(%{kind: :mcp, session_id: ^session_id}, request) and
        Map.has_key?(state.sessions, session_id)

    {:reply, admitted?, state}
  end

  def handle_call({:handler_worker_admit, ref, pid}, _from, state) do
    case Map.get(state.pending_agent_requests, ref) do
      request when is_map(request) and state.status == :ready ->
        pending = Map.put(state.pending_agent_requests, ref, Map.put(request, :worker, pid))
        {:reply, true, %{state | pending_agent_requests: pending}}

      _cancelled ->
        {:reply, false, state}
    end
  end

  # Not ready
  def handle_call(_request, _from, %{status: status} = state) when status != :ready do
    {:reply, {:error, {:not_ready, status}}, state}
  end

  @impl true
  def handle_cast({:cancel, session_id}, state) do
    state = cancel_pending_interactions(session_id, state)
    msg = Protocol.encode_session_cancel(session_id)
    send_to_transport(msg, state)
    {:noreply, state}
  end

  def handle_cast({:cancel_request, request_id}, state) do
    msg = Protocol.encode_cancel_request(request_id)
    send_to_transport(msg, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:transport_message, receiver, raw_message}, state) when is_pid(receiver) do
    result = handle_info({:transport_message, raw_message}, state)
    send(receiver, {:transport_message_ack, self()})
    result
  end

  def handle_info({:transport_message, _raw_message}, %{status: :disconnected} = state) do
    {:noreply, state}
  end

  def handle_info({:transport_message, raw_message}, state)
      when is_binary(raw_message) and byte_size(raw_message) > state.max_frame_bytes do
    Logger.warning("ACP client closed an oversized inbound frame",
      size: byte_size(raw_message),
      limit: state.max_frame_bytes
    )

    state = do_disconnect(state)
    {:noreply, state}
  end

  def handle_info({:transport_message, raw_message}, state) do
    state =
      case Protocol.parse_message_with_context(raw_message) do
        {:ok, parsed, message} -> handle_parsed_message(parsed, state, message)
        error -> handle_parsed_message(error, state)
      end

    {:noreply, state}
  end

  def handle_info({:acp_handler_result, ref, result}, state) do
    state = handle_handler_result(ref, result, state)
    {:noreply, state}
  end

  def handle_info({:acp_mcp_provider_result, ref, outcome}, state) do
    {:noreply, handle_handler_result(ref, {:mcp, outcome}, state)}
  end

  def handle_info({:pending_request_timeout, request_id}, state) do
    case PendingRequests.pop(state.pending_requests, request_id) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, telemetry_tag, monitor_ref, _timer_ref} = request, pending} ->
        Process.demonitor(monitor_ref, [:flush])
        GenServer.reply(from, {:error, :request_timeout})

        state = %{
          state
          | pending_requests: pending,
            pending_caller_monitors: Map.delete(state.pending_caller_monitors, monitor_ref)
        }

        state = clear_abandoned_prompt_text(request, state)
        state = abort_mcp_plan(state, request_id)
        emit_resolve_telemetry(telemetry_tag, {:error, :request_timeout})

        if state.status == :ready do
          send_to_transport(Protocol.encode_cancel_request(request_id), state)
        end

        {:noreply, state}
    end
  end

  def handle_info({:agent_handler_timeout, ref}, state) do
    case PendingRequests.pop(state.pending_agent_requests, ref) do
      {nil, _pending} ->
        {:noreply, state}

      {request, pending} ->
        stop_mcp_worker(request)
        state = finish_mcp_request(%{state | pending_agent_requests: pending}, request)

        message =
          if request.kind == :mcp,
            do: "MCP provider unavailable",
            else: "Client handler timed out"

        response = Protocol.encode_error(-32603, message, nil, request.id)
        send_to_transport(response, state)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{scope_monitor: ref} = state)
      when is_reference(ref),
      do: {:stop, :normal, do_disconnect(state)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{transport_actor_monitor: ref} = state)
      when is_reference(ref) do
    state = %{state | transport_actor_monitor: nil}

    if reason == :normal do
      # The pull receiver still carries the terminal result, including any
      # cleanup failure. Its one-frame handoff preserves ordered admission.
      {:noreply, state}
    else
      state = reply_all_pending({:error, {:transport_error, {:actor_down, reason}}}, state)
      {:noreply, do_disconnect(state)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.mcp_provider_monitors, ref) do
      {server_id, monitors} when is_binary(server_id) ->
        state = %{
          state
          | mcp_provider_monitors: monitors,
            mcp_providers: Map.delete(state.mcp_providers, server_id)
        }

        {:noreply, fail_provider_requests(state, server_id)}

      {nil, _monitors} ->
        case Map.fetch(state.pending_caller_monitors, ref) do
          :error ->
            subscribers =
              Map.reject(state.extension_subscribers, fn {_pid, entry} -> entry.monitor == ref end)

            {:noreply, %{state | extension_subscribers: subscribers}}

          {:ok, request_id} ->
            monitors = Map.delete(state.pending_caller_monitors, ref)
            {pending, requests} = PendingRequests.pop(state.pending_requests, request_id)
            cancel_pending_timer(pending)
            state = %{state | pending_requests: requests, pending_caller_monitors: monitors}
            state = clear_abandoned_prompt_text(pending, state)
            state = abort_mcp_plan(state, request_id)

            if state.status == :ready do
              send_to_transport(Protocol.encode_cancel_request(request_id), state)
            end

            {:noreply, state}
        end
    end
  end

  def handle_info({:transport_closed, reason}, state) do
    Logger.info("ACP transport closed")
    state = reply_all_pending({:error, :transport_closed}, state)

    state = %{
      state
      | cleanup_result: remember_cleanup(state.cleanup_result, terminal_cleanup(reason))
    }

    {:noreply, do_disconnect(state)}
  end

  def handle_info({:transport_error, reason}, state) do
    Logger.warning("ACP transport error",
      reason_shape: LogSummary.describe(reason)
    )

    state = reply_all_pending({:error, {:transport_error, reason}}, state)

    state = %{
      state
      | cleanup_result: remember_cleanup(state.cleanup_result, terminal_cleanup(reason))
    }

    {:noreply, do_disconnect(state)}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      pid == state.receiver_pid ->
        if reason != :normal do
          Logger.warning("ACP receiver exited",
            reason_shape: LogSummary.describe(reason)
          )
        end

        state = reply_all_pending({:error, :receiver_exited}, state)
        {:noreply, do_disconnect(%{state | receiver_pid: nil})}

      pid == state.handler_pid ->
        Logger.warning("ACP handler runner exited",
          reason_shape: LogSummary.describe(reason)
        )

        state = fail_pending_agent_requests("Handler unavailable", state)
        {:noreply, %{state | handler_pid: nil}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:acp_mcp_worker, ref, pid}, state) when is_reference(ref) and is_pid(pid) do
    case Map.get(state.pending_agent_requests, ref) do
      nil ->
        Process.exit(pid, :kill)
        {:noreply, state}

      request ->
        pending =
          PendingRequests.put(state.pending_agent_requests, ref, Map.put(request, :worker, pid))

        {:noreply, %{state | pending_agent_requests: pending}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_parsed_message({:notification, "session/update", params}, state, message) do
    case RequestValidation.normalize_session_update(params) do
      {:ok, params} ->
        cond do
          not authorized_session_id?(params["sessionId"], state) ->
            Logger.warning("ACP client ignored an update for an unknown session")
            state

          not advertised_session_update?(params["update"], state) ->
            Logger.warning("ACP client ignored a session update it did not advertise",
              session_update: params["update"]["sessionUpdate"]
            )

            state

          true ->
            handle_session_update(params, state, message)
        end

      {:error, :invalid_params} ->
        Logger.warning("ACP client ignored an invalid session update")
        state
    end
  end

  defp handle_parsed_message({:request, method, params, id}, state, message),
    do: validate_and_handle_agent_request(method, params, id, state, message)

  defp handle_parsed_message({:notification, "_" <> _ = method, params}, state, _message),
    do: handle_extension_notification(method, params, state)

  defp handle_parsed_message(parsed, state, _message), do: handle_parsed_message(parsed, state)

  defp handle_parsed_message({:result, result, id}, state),
    do: resolve_pending(id, {:ok, result}, state)

  defp handle_parsed_message({:error, error, id}, state),
    do: resolve_pending(id, {:error, error}, state)

  defp handle_parsed_message({:notification, "$/cancel_request", params}, state),
    do: handle_cancel_request_notification(params, state)

  defp handle_parsed_message(
         {:notification, "elicitation/complete", %{"elicitationId" => elicitation_id}},
         state
       )
       when is_binary(elicitation_id) and elicitation_id != "" do
    if is_map(state.client_capabilities |> Maps.get("elicitation") |> Maps.get("url")) &&
         state.handler_pid &&
         function_exported?(state.handler_mod, :handle_elicitation_complete, 2) do
      HandlerRunner.elicitation_complete(state.handler_pid, elicitation_id)
    end

    state
  end

  defp handle_parsed_message(other, state) do
    Logger.debug("ACP client received unexpected message",
      message_shape: LogSummary.describe(other)
    )

    state
  end

  @impl true
  def terminate(_reason, state) do
    do_disconnect(state)
    :ok
  end

  # Private helpers

  defp init_client(opts, scope, scope_monitor) do
    case normalize_provider_map(Keyword.get(opts, :mcp_providers, %{})) do
      {:ok, providers} -> start_client(opts, scope, scope_monitor, providers)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_client(opts, scope, scope_monitor, providers) do
    handler_mod = Keyword.get(opts, :handler, DefaultHandler)
    handler_opts = Keyword.get(opts, :handler_opts, [])

    case HandlerRunner.start_link(handler_mod, handler_opts, self(), scope) do
      {:ok, handler_pid} ->
        state = %__MODULE__{
          connection_scope: scope,
          scope_monitor: scope_monitor,
          transport_mod: Keyword.get(opts, :transport_mod, Stdio),
          handler_mod: handler_mod,
          handler_pid: handler_pid,
          event_listener: Keyword.get(opts, :event_listener),
          protocol_version: Keyword.get(opts, :protocol_version, 1),
          max_frame_bytes:
            Options.positive_integer(opts, :max_frame_bytes, @default_max_frame_bytes),
          max_pending_requests:
            Options.positive_integer(opts, :max_pending_requests, @default_max_pending_requests),
          max_prompt_text_bytes:
            Options.positive_integer(opts, :max_prompt_text_bytes, @default_max_prompt_text_bytes),
          pending_request_timeout:
            Options.positive_integer(
              opts,
              :pending_request_timeout,
              @default_pending_request_timeout
            ),
          handler_request_timeout:
            Options.positive_integer(
              opts,
              :handler_request_timeout,
              @default_handler_request_timeout
            ),
          max_update_queue:
            Options.positive_integer(opts, :max_update_queue, @default_max_update_queue),
          max_update_queue_bytes:
            Options.positive_integer(
              opts,
              :max_update_queue_bytes,
              @default_max_update_queue_bytes
            )
        }

        state =
          Enum.reduce(providers, state, fn {id, provider}, state ->
            put_provider(state, id, provider)
          end)

        # Allow skipping connection for tests
        if Keyword.get(opts, :_skip_connect) do
          {:ok, %{state | status: :ready}}
        else
          case connect_and_initialize(opts, state) do
            {:ok, state} -> {:ok, state}
            {:error, reason} -> {:stop, reason}
          end
        end

      {:error, reason} ->
        {:stop, {:handler_init_failed, reason}}
    end
  end

  defp start_prompt(session_id, content, mode, from, state, meta \\ nil) do
    with true <- is_nil(meta) or (is_map(meta) and Extensions.json?(meta)),
         {:ok, blocks} <- prompt_blocks(content),
         :ok <- validate_prompt_blocks(state, blocks),
         :ok <- admit_prompt(state, session_id, mode) do
      :telemetry.execute(
        [:arbor_acp, :prompt, :sent],
        %{system_time: System.system_time()},
        %{session_id_hash: session_id_hash(session_id)}
      )

      msg = Protocol.encode_session_prompt(session_id, blocks)
      msg = if is_nil(meta), do: msg, else: put_in(msg, ["params", "_meta"], meta)
      state = begin_prompt_collection(state, session_id, mode)

      case send_request(msg, from, state, {:prompt, session_id}) do
        {:reply, reply, state} ->
          {:reply, reply, %{state | prompt_text: Map.delete(state.prompt_text, session_id)}}

        deferred ->
          deferred
      end
    else
      false ->
        {:reply, {:error, :invalid_meta}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp connect_and_initialize(opts, state) do
    transport_opts = build_transport_opts(opts)

    with {:ok, initialize_timeout} <- initialize_timeout(opts),
         {:ok, transport_state} <- state.transport_mod.connect(transport_opts) do
      case ConnectionScope.transport(state.connection_scope, state.transport_mod, transport_state) do
        :ok ->
          :ok

        {:error, reason} ->
          state.transport_mod.close(transport_state)
          exit(reason)
      end

      state = start_initialization_receiver(state, transport_state)

      case initialize_connection(opts, state, initialize_timeout) do
        {:ok, initialized_state} ->
          {:ok, initialized_state}

        {:error, reason} = error ->
          state = %{state | cleanup_result: terminal_cleanup(reason)}

          case cleanup_failed_initialization(state) do
            :ok ->
              error

            {:error, _} = cleanup ->
              if cleanup == terminal_cleanup(reason),
                do: error,
                else: {:error, {:cleanup_failed, reason, cleanup}}
          end
      end
    end
  end

  defp start_initialization_receiver(state, transport_state) do
    monitor =
      if state.transport_mod == Stdio do
        case Stdio.linked_processes(transport_state) do
          [actor] -> Process.monitor(actor)
          _ -> nil
        end
      end

    receiver_pid =
      start_receiver(self(), state.transport_mod, transport_state, state.connection_scope)

    %{
      state
      | transport_state: transport_state,
        receiver_pid: receiver_pid,
        transport_actor_monitor: monitor,
        cleanup_result: :ok
    }
  end

  defp initialize_connection(opts, state, initialize_timeout) do
    client_info =
      Keyword.get(opts, :client_info, %{"name" => "ex_mcp", "version" => "0.1.0"})

    # Per ACP spec: "capabilities omitted in initialize MUST be treated
    # as UNSUPPORTED." Auto-advertise fs/terminal capabilities based on
    # whether the handler module exports the corresponding callbacks —
    # otherwise the agent will never call them even if the handler can
    # answer. Explicit :capabilities opt takes precedence.
    auto_capabilities = auto_advertise_capabilities(state.handler_mod)
    explicit_capabilities = Keyword.get(opts, :capabilities)
    capabilities = Capabilities.merge(auto_capabilities, explicit_capabilities)

    init_msg = Protocol.encode_initialize(client_info, capabilities, state.protocol_version)

    with {:ok, _} <- do_send(init_msg, state),
         {:ok, result} when is_map(result) <-
           receive_init_response(init_msg["id"], initialize_timeout, state.max_frame_bytes),
         protocol_version <- Map.get(result, "protocolVersion"),
         :ok <-
           RequestValidation.validate_protocol_version(
             protocol_version,
             @supported_protocol_versions
           ) do
      {:ok,
       %{
         state
         | initialize_result: result,
           agent_info: result["agentInfo"],
           agent_capabilities: result["agentCapabilities"],
           client_capabilities: capabilities,
           auth_methods: result["authMethods"] || [],
           protocol_version: protocol_version,
           status: :ready
       }}
    else
      {:ok, _invalid_result} -> {:error, :invalid_initialize_response}
      {:error, :invalid_protocol_version} -> {:error, :invalid_initialize_protocol_version}
      {:error, _reason} = error -> error
    end
  end

  defp initialize_timeout(opts) do
    case Keyword.get(opts, :initialize_timeout, @default_initialize_timeout) do
      timeout
      when is_integer(timeout) and timeout > 0 and timeout <= @maximum_initialize_timeout ->
        {:ok, timeout}

      _invalid ->
        {:error, :invalid_initialize_timeout}
    end
  end

  defp cleanup_failed_initialization(state) do
    do_disconnect(state).cleanup_result
  rescue
    exception -> {:error, {:cleanup_exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {:cleanup_failed, kind, reason}}
  end

  @client_keys [
    :name,
    :handler,
    :handler_opts,
    :event_listener,
    :client_info,
    :capabilities,
    :protocol_version,
    :initialize_timeout,
    :max_pending_requests,
    :max_prompt_text_bytes,
    :pending_request_timeout,
    :handler_request_timeout,
    :max_update_queue,
    :max_update_queue_bytes,
    :transport_mod,
    :mcp_providers,
    :_skip_connect,
    :_connection_scope
  ]

  defp build_transport_opts(opts) do
    # Pass all non-client keys to the transport (command, cd, env, plus any test keys)
    Keyword.drop(opts, @client_keys)
  end

  defp start_receiver(parent, transport_mod, transport_state, scope) do
    pid =
      spawn_link(fn ->
        receive do
          :start -> receiver_loop(parent, transport_mod, transport_state)
        end
      end)

    case ConnectionScope.register(scope, :receiver, pid) do
      :ok ->
        send(pid, :start)
        pid

      {:error, reason} ->
        Process.exit(pid, :kill)
        exit(reason)
    end
  end

  defp receiver_loop(parent, transport_mod, transport_state) do
    case transport_mod.receive_message(transport_state) do
      {:ok, message, new_state} ->
        send(parent, {:transport_message, self(), message})

        receive do
          {:transport_message_ack, ^parent} ->
            receiver_loop(parent, transport_mod, new_state)
        end

      {:error, :closed} ->
        send(parent, {:transport_closed, :normal})

      {:error, reason} ->
        send(parent, {:transport_error, reason})
    end
  end

  defp receive_init_response(request_id, timeout, max_frame_bytes) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_receive_init_response(request_id, deadline, max_frame_bytes)
  end

  defp do_receive_init_response(request_id, deadline, max_frame_bytes) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:error, :init_timeout}
    else
      receive do
        {:transport_message, receiver, raw} when is_pid(receiver) ->
          send(receiver, {:transport_message_ack, self()})
          handle_init_frame(raw, request_id, deadline, max_frame_bytes)

        {:transport_message, raw} ->
          handle_init_frame(raw, request_id, deadline, max_frame_bytes)

        {:transport_error, reason} ->
          {:error, reason}

        {:transport_closed, reason} ->
          {:error, {:transport_closed, reason}}
      after
        remaining ->
          {:error, :init_timeout}
      end
    end
  end

  defp handle_init_frame(raw, request_id, deadline, max_frame_bytes) do
    if is_binary(raw) and byte_size(raw) > max_frame_bytes do
      {:error, :frame_too_large}
    else
      case Protocol.parse_message(raw) do
        {:result, result, ^request_id} ->
          {:ok, result}

        {:error, error, ^request_id} ->
          {:error, {:agent_error, error}}

        _other ->
          # Skip non-matching messages during init without resetting the deadline.
          do_receive_init_response(request_id, deadline, max_frame_bytes)
      end
    end
  end

  defp send_request(msg, from, state, telemetry_tag \\ nil) do
    id = msg["id"]

    cond do
      Map.has_key?(state.pending_requests, id) ->
        {:reply, {:error, :duplicate_request_id}, state}

      map_size(state.pending_requests) >= state.max_pending_requests ->
        {:reply, {:error, :too_many_pending_requests}, state}

      true ->
        case do_send(msg, state) do
          {:ok, new_state} ->
            monitor_ref = Process.monitor(elem(from, 0))

            timer_ref =
              Process.send_after(
                self(),
                {:pending_request_timeout, id},
                state.pending_request_timeout
              )

            pending =
              PendingRequests.put(
                state.pending_requests,
                id,
                {from, telemetry_tag, monitor_ref, timer_ref}
              )

            monitors = Map.put(state.pending_caller_monitors, monitor_ref, id)

            {:noreply,
             %{
               new_state
               | pending_requests: pending,
                 pending_caller_monitors: monitors
             }}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  defp send_to_transport(msg, state) do
    case do_send(msg, state) do
      {:ok, _state} ->
        :ok

      {:error, reason} ->
        Logger.warning("ACP send failed",
          reason_shape: LogSummary.describe(reason)
        )
    end
  end

  defp do_send(msg, state) do
    encoded = Jason.encode!(msg)

    if byte_size(encoded) > state.max_frame_bytes do
      {:error, :frame_too_large}
    else
      case state.transport_mod.send_message(encoded, state.transport_state) do
        {:ok, new_transport_state} ->
          {:ok, %{state | transport_state: new_transport_state}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_pending(id, reply, state) do
    case PendingRequests.pop(state.pending_requests, id) do
      {nil, _pending} ->
        Logger.debug("ACP received response for unknown request",
          request_id_hash: LogSummary.fingerprint(id)
        )

        state

      {{from, telemetry_tag, monitor_ref, timer_ref}, pending} ->
        cancel_timer(timer_ref)
        Process.demonitor(monitor_ref, [:flush])
        omitted = mcp_plan_omissions(state, id)
        {reply, state} = settle_mcp_plan(id, telemetry_tag, reply, state)
        state = apply_session_resolution(telemetry_tag, reply, state)
        emit_resolve_telemetry(telemetry_tag, reply)
        {reply, state} = finish_prompt_collection(telemetry_tag, reply, state)
        GenServer.reply(from, with_omitted_servers(reply, omitted))

        %{
          state
          | pending_requests: pending,
            pending_caller_monitors: Map.delete(state.pending_caller_monitors, monitor_ref)
        }

      {{from, telemetry_tag}, pending} ->
        emit_resolve_telemetry(telemetry_tag, reply)
        {reply, state} = finish_prompt_collection(telemetry_tag, reply, state)
        GenServer.reply(from, reply)
        %{state | pending_requests: pending}

      {from, pending} ->
        GenServer.reply(from, reply)
        %{state | pending_requests: pending}
    end
  end

  defp finish_prompt_collection({:prompt, session_id}, {:ok, result}, state) do
    {buffered, prompt_text} = Map.pop(state.prompt_text, session_id)

    reply =
      case buffered do
        nil ->
          {:ok, result}

        %{text: text, truncated?: truncated?} when is_map(result) ->
          {:ok, %{result: result, text: text, truncated?: truncated?}}

        _invalid_result ->
          {:error, :invalid_prompt_response}
      end

    {reply, %{state | prompt_text: prompt_text}}
  end

  defp finish_prompt_collection({:prompt, session_id}, reply, state) do
    {_, prompt_text} = Map.pop(state.prompt_text, session_id)
    {reply, %{state | prompt_text: prompt_text}}
  end

  defp finish_prompt_collection(_tag, reply, state), do: {reply, state}

  defp emit_resolve_telemetry({:new_session, _roots}, {:ok, result}) do
    session_id = result["sessionId"]

    :telemetry.execute(
      [:arbor_acp, :session, :started],
      %{system_time: System.system_time()},
      %{session_id_hash: session_id_hash(session_id)}
    )
  end

  defp emit_resolve_telemetry({:prompt, session_id}, {:ok, result}) when is_map(result) do
    stop_reason = result["stopReason"]

    :telemetry.execute(
      [:arbor_acp, :prompt, :completed],
      %{system_time: System.system_time()},
      %{session_id_hash: session_id_hash(session_id), stop_reason: stop_reason}
    )
  end

  defp emit_resolve_telemetry({:close_session, session_id}, {:ok, _result}) do
    emit_session_ended(session_id)
  end

  defp emit_resolve_telemetry(_, _), do: :ok

  defp apply_session_resolution(
         {:new_session, roots},
         {:ok, %{"sessionId" => session_id}},
         state
       )
       when is_binary(session_id) and session_id != "" do
    %{state | sessions: Map.put(state.sessions, session_id, %{roots: roots})}
  end

  defp apply_session_resolution({kind, session_id, roots}, {:ok, _result}, state)
       when kind in [:load_session, :resume_session] and is_binary(session_id) and
              session_id != "" do
    %{state | sessions: Map.put(state.sessions, session_id, %{roots: roots})}
  end

  defp apply_session_resolution(
         {:fork_session, roots},
         {:ok, %{"sessionId" => session_id}},
         state
       )
       when is_binary(session_id) and session_id != "" do
    %{state | sessions: Map.put(state.sessions, session_id, %{roots: roots})}
  end

  defp apply_session_resolution({kind, session_id}, {:ok, _result}, state)
       when kind in [:close_session, :delete_session] do
    %{state | sessions: Map.delete(state.sessions, session_id)}
  end

  defp apply_session_resolution(_tag, _reply, state), do: state

  # Build a clientCapabilities map reflecting which optional ACP callbacks
  # the handler module actually exports. Per spec, capabilities omitted in
  # initialize MUST be treated as unsupported — so a missing advertisement
  # means the agent will never invoke that capability.
  defp auto_advertise_capabilities(nil), do: nil

  defp auto_advertise_capabilities(handler_mod) when is_atom(handler_mod) do
    Code.ensure_loaded(handler_mod)

    fs =
      %{}
      |> maybe_put_cap("readTextFile", function_exported?(handler_mod, :handle_file_read, 4))
      |> maybe_put_cap("writeTextFile", function_exported?(handler_mod, :handle_file_write, 4))

    caps = %{}
    caps = if map_size(fs) > 0, do: Map.put(caps, "fs", fs), else: caps

    elicitation =
      %{}
      |> maybe_put_cap("form", function_exported?(handler_mod, :handle_form_elicitation, 2), %{})
      |> maybe_put_cap("url", function_exported?(handler_mod, :handle_url_elicitation, 2), %{})

    caps =
      if map_size(elicitation) > 0,
        do: Map.put(caps, "elicitation", elicitation),
        else: caps

    caps =
      if function_exported?(handler_mod, :handle_terminal_request, 4) do
        Map.put(caps, "terminal", true)
      else
        caps
      end

    if map_size(caps) > 0, do: caps, else: nil
  end

  defp maybe_put_cap(map, _key, false), do: map
  defp maybe_put_cap(map, key, true), do: Map.put(map, key, true)
  defp maybe_put_cap(map, _key, false, _value), do: map
  defp maybe_put_cap(map, key, true, value), do: Map.put(map, key, value)

  # Explicit :capabilities opt fully replaces auto-detected. Auto only
  # fills in when no explicit caps are passed. This preserves the
  # contract that `capabilities: %{}` means "advertise nothing" —
  # otherwise auto-fill from handler exports would override a caller's
  # explicit suppression.
  defp emit_session_ended(session_id) do
    :telemetry.execute(
      [:arbor_acp, :session, :ended],
      %{system_time: System.system_time()},
      %{session_id_hash: session_id_hash(session_id)}
    )
  end

  defp session_id_hash(session_id), do: LogSummary.fingerprint({:acp_session, session_id})

  defp ensure_capability(state, capability) do
    Capabilities.ensure(state.agent_capabilities || %{}, capability)
  end

  defp prompt_blocks(text) when is_binary(text), do: {:ok, [%{"type" => "text", "text" => text}]}
  defp prompt_blocks(blocks) when is_list(blocks), do: {:ok, blocks}
  defp prompt_blocks(_content), do: {:error, {:invalid_params, :prompt_must_be_a_list}}

  defp validate_prompt_blocks(state, blocks) when is_list(blocks) do
    Enum.reduce_while(blocks, :ok, fn block, :ok ->
      case validate_prompt_block(state.agent_capabilities || %{}, block) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_prompt_block(_caps, %{"type" => type}) when type in ["text", "resource_link"],
    do: :ok

  defp validate_prompt_block(caps, %{"type" => "image"}) do
    validate_prompt_capability(caps, "image", :image)
  end

  defp validate_prompt_block(caps, %{"type" => "audio"}) do
    validate_prompt_capability(caps, "audio", :audio)
  end

  defp validate_prompt_block(caps, %{"type" => "resource"}) do
    validate_prompt_capability(caps, "embeddedContext", :embedded_context)
  end

  defp validate_prompt_block(_caps, %{"type" => type}) do
    {:error, {:unsupported_prompt_content, type}}
  end

  defp validate_prompt_block(_caps, _block), do: {:error, {:invalid_params, :prompt_block}}

  defp validate_prompt_capability(caps, key, capability) do
    if caps |> Maps.get("promptCapabilities") |> Maps.get(key) |> Maps.truthy?() do
      :ok
    else
      {:error, {:unsupported_capability, {:prompt, capability}}}
    end
  end

  defp reply_all_pending(error, state) do
    refuse_handler_mcp(state)

    for pending <- PendingRequests.values(state.pending_requests) do
      case pending do
        {from, _tag, monitor_ref, timer_ref} ->
          cancel_timer(timer_ref)
          Process.demonitor(monitor_ref, [:flush])
          GenServer.reply(from, error)

        {from, _tag, monitor_ref} ->
          Process.demonitor(monitor_ref, [:flush])
          GenServer.reply(from, error)

        {from, _tag} ->
          GenServer.reply(from, error)

        from ->
          GenServer.reply(from, error)
      end
    end

    Enum.each(state.pending_agent_requests, fn {_ref, request} ->
      cancel_timer(Map.get(request, :timer_ref))
      stop_mcp_worker(request)
    end)

    %{
      state
      | pending_requests: PendingRequests.empty(),
        pending_caller_monitors: %{},
        pending_agent_requests: %{},
        prompt_text: %{},
        sessions: %{},
        mcp: Mcp.new(),
        mcp_plans: %{}
    }
  end

  # ACP v1: agents MUST only send these updates after the client advertised the
  # matching `clientCapabilities.session` entry; `{}` advertises it, while an
  # omitted or null entry does not. Dropping them keeps handlers that never
  # opted in from receiving update kinds they did not ask for.
  defp advertised_session_update?(%{"sessionUpdate" => "notice"}, state),
    do: advertised_client_session_capability?(state, "notices")

  defp advertised_session_update?(%{"sessionUpdate" => type}, state)
       when type in ["compaction_update", "compaction_summary_chunk"],
       do: advertised_client_session_capability?(state, "compaction")

  defp advertised_session_update?(_update, _state), do: true

  defp advertised_client_session_capability?(state, key),
    do: is_map(state.client_capabilities |> Maps.get("session") |> Maps.get(key))

  defp handle_session_update(params, state, message) do
    session_id = params["sessionId"]
    update = params["update"]
    update_bytes = :erlang.external_size(update)

    # Retain text only for an explicitly collecting prompt.
    state = accumulate_prompt_text(state, session_id, update)

    # Notify event listener from the client process so a slow handler cannot
    # stall the update stream.
    if is_pid(state.event_listener) and
         update_mailbox_below_limits?(
           state.event_listener,
           state.max_update_queue,
           state.max_update_queue_bytes,
           update_bytes,
           :listener
         ) do
      send(state.event_listener, {:acp_session_update, session_id, update})
    end

    if state.handler_pid do
      HandlerRunner.session_update(
        state.handler_pid,
        session_id,
        update,
        state.max_update_queue,
        state.max_update_queue_bytes,
        handler_message(state, :handle_session_update, 4, message)
      )
    end

    state
  end

  defp handle_extension_notification(method, params, state) do
    event = {:acp_extension_notification, method, params}

    subscribers =
      Enum.filter(state.extension_subscribers, fn {_pid, entry} ->
        entry.methods == :all or method in entry.methods
      end)

    room? =
      Enum.all?(subscribers, fn {pid, _} ->
        update_mailbox_below_limits?(
          pid,
          state.max_update_queue,
          state.max_update_queue_bytes,
          :erlang.external_size(event),
          :listener
        )
      end)

    handler_result =
      if state.handler_pid &&
           function_exported?(state.handler_mod, :handle_extension_notification, 3) do
        HandlerRunner.extension_notification(
          state.handler_pid,
          method,
          params,
          state.max_update_queue,
          state.max_update_queue_bytes
        )
      else
        :ok
      end

    if room? and handler_result == :ok do
      Enum.each(subscribers, fn {pid, _} -> send(pid, event) end)
      state
    else
      Logger.warning("ACP extension consumer queue is full; closing connection")
      do_disconnect(state)
    end
  end

  defp admit_prompt(state, session_id, mode) do
    if Map.has_key?(state.prompt_text, session_id) or
         (mode != :raw and prompt_pending?(state, session_id)),
       do: {:error, :prompt_in_progress},
       else: :ok
  end

  defp begin_prompt_collection(state, _session_id, :raw), do: state

  defp begin_prompt_collection(state, session_id, {:collect, limit}) do
    limit = min(limit || state.max_prompt_text_bytes, state.max_prompt_text_bytes)
    buffer = %{text: "", limit: limit, truncated?: false}
    %{state | prompt_text: Map.put(state.prompt_text, session_id, buffer)}
  end

  defp accumulate_prompt_text(
         state,
         session_id,
         %{
           "sessionUpdate" => "agent_message_chunk",
           "content" => %{"type" => "text", "text" => text}
         }
       )
       when is_binary(text) do
    case Map.get(state.prompt_text, session_id) do
      %{text: buffered, limit: limit, truncated?: false} = buffer ->
        prefix = valid_utf8_prefix(text, max(limit - byte_size(buffered), 0))

        buffer = %{
          buffer
          | text: buffered <> prefix,
            truncated?: byte_size(prefix) < byte_size(text)
        }

        %{state | prompt_text: Map.put(state.prompt_text, session_id, buffer)}

      _not_collecting ->
        state
    end
  end

  defp accumulate_prompt_text(state, _session_id, _update), do: state

  defp prompt_pending?(state, session_id) do
    Enum.any?(state.pending_requests, fn
      {_id, {_from, {:prompt, ^session_id}, _monitor_ref}} -> true
      {_id, {_from, {:prompt, ^session_id}, _monitor_ref, _timer_ref}} -> true
      {_id, {_from, {:prompt, ^session_id}}} -> true
      _ -> false
    end)
  end

  defp clear_abandoned_prompt_text({_from, {:prompt, session_id}, _monitor_ref}, state),
    do: %{state | prompt_text: Map.delete(state.prompt_text, session_id)}

  defp clear_abandoned_prompt_text(
         {_from, {:prompt, session_id}, _monitor_ref, _timer_ref},
         state
       ),
       do: %{state | prompt_text: Map.delete(state.prompt_text, session_id)}

  defp clear_abandoned_prompt_text(_pending, state), do: state

  defp validate_and_handle_agent_request(method, params, id, state, message) do
    with :ok <- ensure_agent_request_id_available(id, state),
         :ok <- ensure_advertised_client_capability(method, params, state),
         :ok <- RequestValidation.validate_agent_request(method, params),
         :ok <- ensure_agent_session_authority(method, params, state),
         :ok <- ensure_agent_request_capacity(state) do
      handle_agent_request(method, params, id, state, message)
    else
      {:error, :duplicate_request_id} ->
        send_agent_request_error(state, id, -32_600, "Request id is already in use")

      {:error, :unsupported_client_capability} ->
        send_agent_request_error(state, id, -32_601, "Method not supported")

      {:error, :method_not_found} ->
        send_agent_request_error(state, id, -32_601, "Method not found")

      {:error, :invalid_params} ->
        send_agent_request_error(state, id, -32_602, "Invalid request parameters")

      {:error, :unknown_session} ->
        send_agent_request_error(state, id, -32_602, "Unknown session")

      {:error, :path_not_authorized} ->
        send_agent_request_error(state, id, -32_602, "Path is outside the session workspace")

      {:error, :too_many_pending_requests} ->
        send_agent_request_error(state, id, -32_000, "Too many pending requests")
    end
  end

  defp ensure_agent_request_id_available(id, state) do
    if Enum.any?(state.pending_agent_requests, fn {_ref, request} -> request.id == id end) do
      {:error, :duplicate_request_id}
    else
      :ok
    end
  end

  defp ensure_advertised_client_capability("fs/read_text_file", _params, state) do
    if state.client_capabilities |> Maps.get("fs") |> Maps.get("readTextFile") == true,
      do: :ok,
      else: {:error, :unsupported_client_capability}
  end

  defp ensure_advertised_client_capability("fs/write_text_file", _params, state) do
    if state.client_capabilities |> Maps.get("fs") |> Maps.get("writeTextFile") == true,
      do: :ok,
      else: {:error, :unsupported_client_capability}
  end

  defp ensure_advertised_client_capability("terminal/" <> _method, _params, state) do
    if Maps.get(state.client_capabilities, "terminal") == true,
      do: :ok,
      else: {:error, :unsupported_client_capability}
  end

  defp ensure_advertised_client_capability("elicitation/create", %{"mode" => mode}, state) do
    if is_map(state.client_capabilities |> Maps.get("elicitation") |> Maps.get(mode)),
      do: :ok,
      else: {:error, :unsupported_client_capability}
  end

  defp ensure_advertised_client_capability(_method, _params, _state), do: :ok

  defp ensure_agent_session_authority("session/request_permission", params, state) do
    ensure_known_session(params["sessionId"], state)
  end

  defp ensure_agent_session_authority("elicitation/create", %{"sessionId" => session_id}, state) do
    ensure_known_session(session_id, state)
  end

  defp ensure_agent_session_authority("elicitation/create", %{"requestId" => request_id}, state) do
    if Map.has_key?(state.pending_requests, request_id),
      do: :ok,
      else: {:error, :unknown_session}
  end

  defp ensure_agent_session_authority(method, params, state)
       when method in ["fs/read_text_file", "fs/write_text_file"] do
    with {:ok, roots} <- session_roots_for(params["sessionId"], state),
         true <- path_within_roots?(params["path"], roots) do
      :ok
    else
      {:error, :unknown_session} -> {:error, :unknown_session}
      false -> {:error, :path_not_authorized}
    end
  end

  defp ensure_agent_session_authority("terminal/create", params, state) do
    with {:ok, roots} <- session_roots_for(params["sessionId"], state) do
      case params["cwd"] do
        nil -> :ok
        cwd -> if path_within_roots?(cwd, roots), do: :ok, else: {:error, :path_not_authorized}
      end
    end
  end

  defp ensure_agent_session_authority("terminal/" <> _method, params, state) do
    ensure_known_session(params["sessionId"], state)
  end

  defp ensure_agent_session_authority(_method, _params, _state), do: :ok

  defp authorized_session_id?(session_id, state)
       when is_binary(session_id) and session_id != "" do
    Map.has_key?(state.sessions, session_id) or pending_session_open?(session_id, state)
  end

  defp authorized_session_id?(_session_id, _state), do: false

  defp ensure_known_session(session_id, state) do
    if authorized_session_id?(session_id, state), do: :ok, else: {:error, :unknown_session}
  end

  defp session_roots_for(session_id, state) do
    case Map.get(state.sessions, session_id) do
      %{roots: roots} when is_list(roots) -> {:ok, roots}
      _missing -> pending_session_roots(session_id, state)
    end
  end

  defp pending_session_open?(session_id, state) do
    match?({:ok, _roots}, pending_session_roots(session_id, state))
  end

  defp pending_session_roots(session_id, state) do
    Enum.any?(state.pending_requests, fn
      {_id, {_from, {kind, ^session_id, _roots}, _monitor_ref, _timer_ref}}
      when kind in [:load_session, :resume_session] ->
        true

      _pending ->
        false
    end)
    |> case do
      false ->
        {:error, :unknown_session}

      true ->
        {_id, {_from, {_kind, ^session_id, roots}, _monitor_ref, _timer_ref}} =
          Enum.find(state.pending_requests, fn
            {_id, {_from, {kind, candidate, _roots}, _monitor_ref, _timer_ref}} ->
              kind in [:load_session, :resume_session] and candidate == session_id

            _pending ->
              false
          end)

        {:ok, roots}
    end
  end

  defp ensure_agent_request_capacity(state) do
    if map_size(state.pending_agent_requests) < state.max_pending_requests,
      do: :ok,
      else: {:error, :too_many_pending_requests}
  end

  defp send_agent_request_error(state, id, code, message) do
    response = Protocol.encode_error(code, message, nil, id)
    send_to_transport(response, state)
    state
  end

  defp handle_agent_request("session/request_permission", params, id, state, message) do
    session_id = params["sessionId"]
    tool_call = params["toolCall"]
    options = params["options"] || []

    if state.handler_pid do
      ref = HandlerRunner.new_request_ref()

      HandlerRunner.permission_request(
        state.handler_pid,
        ref,
        session_id,
        tool_call,
        options,
        handler_message(state, :handle_permission_request, 5, message)
      )

      track_agent_request(state, ref, :permission, id, session_id)
    else
      response = Protocol.encode_error(-32603, "Handler unavailable", nil, id)
      send_to_transport(response, state)
      state
    end
  end

  defp handle_agent_request(method, params, id, state, _message),
    do: handle_agent_request(method, params, id, state)

  defp handler_message(state, callback, arity, message) do
    if function_exported?(state.handler_mod, callback, arity), do: message
  end

  defp handle_agent_request("elicitation/create", params, id, state) do
    mode = params["mode"]
    callback = if mode == "form", do: :handle_form_elicitation, else: :handle_url_elicitation

    if state.handler_pid && function_exported?(state.handler_mod, callback, 2) do
      ref = HandlerRunner.new_request_ref()
      HandlerRunner.elicitation_request(state.handler_pid, ref, mode, params)
      track_agent_request(state, ref, :elicitation, id, params["sessionId"], %{mode: mode})
    else
      response = Protocol.encode_error(-32_601, "Elicitation mode not supported", nil, id)
      send_to_transport(response, state)
      state
    end
  end

  defp handle_agent_request("fs/read_text_file", params, id, state) do
    session_id = params["sessionId"]
    path = params["path"]
    opts = Map.drop(params, ["sessionId", "path"])

    if state.handler_pid && function_exported?(state.handler_mod, :handle_file_read, 4) do
      ref = HandlerRunner.new_request_ref()
      HandlerRunner.file_read(state.handler_pid, ref, session_id, path, opts)
      track_agent_request(state, ref, :file_read, id, session_id)
    else
      response = Protocol.encode_error(-32601, "File read not supported", nil, id)
      send_to_transport(response, state)
      state
    end
  end

  defp handle_agent_request("fs/write_text_file", params, id, state) do
    session_id = params["sessionId"]
    path = params["path"]
    content = params["content"]

    if state.handler_pid && function_exported?(state.handler_mod, :handle_file_write, 4) do
      ref = HandlerRunner.new_request_ref()
      HandlerRunner.file_write(state.handler_pid, ref, session_id, path, content)
      track_agent_request(state, ref, :file_write, id, session_id)
    else
      response = Protocol.encode_error(-32601, "File write not supported", nil, id)
      send_to_transport(response, state)
      state
    end
  end

  # Terminal operations — spec-defined but delegated to handler
  defp handle_agent_request("terminal/" <> _ = method, params, id, state) do
    if state.handler_pid && function_exported?(state.handler_mod, :handle_terminal_request, 4) do
      params = terminal_params_with_workspace_default(method, params, state)
      ref = HandlerRunner.new_request_ref()
      HandlerRunner.terminal_request(state.handler_pid, ref, method, params, id)
      track_agent_request(state, ref, :terminal, id, params["sessionId"], %{method: method})
    else
      response = Protocol.encode_error(-32601, "Terminal operations not supported", nil, id)
      send_to_transport(response, state)
      state
    end
  end

  defp handle_agent_request("_" <> _ = method, params, id, state) do
    if state.handler_pid && function_exported?(state.handler_mod, :handle_extension_request, 3) do
      ref = HandlerRunner.new_request_ref()
      HandlerRunner.extension_request(state.handler_pid, ref, method, params)
      track_agent_request(state, ref, :extension, id, nil)
    else
      send_agent_request_error(state, id, -32_601, "Extension method not supported")
    end
  end

  defp handle_agent_request("mcp/message", params, id, state) do
    dispatch_mcp_message(params, id, state)
  end

  defp handle_agent_request(method, _params, id, state) do
    Logger.debug("ACP client received unknown agent request",
      method_hash: LogSummary.fingerprint(method)
    )

    response = Protocol.encode_error(-32601, "Method not found: #{method}", nil, id)
    send_to_transport(response, state)
    state
  end

  defp terminal_params_with_workspace_default("terminal/create", params, state) do
    if is_nil(params["cwd"]) do
      case session_roots_for(params["sessionId"], state) do
        {:ok, [cwd | _roots]} -> Map.put(params, "cwd", cwd)
        _missing -> params
      end
    else
      params
    end
  end

  defp terminal_params_with_workspace_default(_method, params, _state), do: params

  defp handle_handler_result(ref, result, state) do
    case PendingRequests.pop(state.pending_agent_requests, ref) do
      {nil, _pending} ->
        state

      {request, pending} ->
        cancel_timer(request.timer_ref)
        state = %{state | pending_agent_requests: pending}
        deliver_handler_response(state, request, encode_handler_response(request, result))
    end
  end

  defp deliver_handler_response(state, request, response) do
    case do_send(response, state) do
      {:ok, state} ->
        finish_mcp_request(state, request)

      {:error, :frame_too_large} ->
        Logger.warning("ACP handler result exceeded the frame cap",
          request_id_hash: LogSummary.fingerprint(request.id)
        )

        state = send_handler_overflow(state, request)
        finish_mcp_request(state, request)

      {:error, reason} ->
        Logger.warning("ACP send failed", reason_shape: LogSummary.describe(reason))
        finish_mcp_request(state, request)
    end
  end

  defp send_handler_overflow(state, request) do
    case do_send(overflow_error(request), state) do
      {:ok, state} ->
        state

      {:error, reason} ->
        Logger.warning("ACP send failed", reason_shape: LogSummary.describe(reason))
        state
    end
  end

  defp overflow_error(%{kind: :mcp, id: id}) do
    Protocol.encode_error(-32603, "MCP provider unavailable", nil, id)
  end

  defp overflow_error(%{id: id}) do
    Protocol.encode_error(-32603, "Client handler failed", nil, id)
  end

  defp encode_handler_response(%{kind: :extension, id: id}, {:extension, {:ok, result}}) do
    if Extensions.json?(result),
      do: Protocol.encode_response(result, id),
      else: Protocol.encode_error(-32_603, "Invalid extension response", nil, id)
  end

  defp encode_handler_response(%{kind: :extension, id: id}, {:extension, {:error, error}}) do
    if Extensions.error?(error),
      do: Arbor.RPC.JSONRPC.error(id, error),
      else: Protocol.encode_error(-32_603, "Extension handler failed", nil, id)
  end

  defp encode_handler_response(%{kind: :permission, id: id}, {:permission, {:ok, outcome}}) do
    Protocol.encode_permission_response(id, outcome)
  end

  defp encode_handler_response(%{kind: :elicitation, id: id}, {:elicitation, {:ok, response}}) do
    response = Maps.stringify_keys(response)

    case RequestValidation.validate_elicitation_response(response) do
      :ok ->
        Protocol.encode_elicitation_response(id, response)

      {:error, :invalid_params} ->
        Protocol.encode_error(-32_603, "Invalid elicitation response", nil, id)
    end
  end

  defp encode_handler_response(%{kind: :file_read, id: id}, {:file_read, {:ok, content}}) do
    Protocol.encode_file_read_response(id, content)
  end

  defp encode_handler_response(%{kind: :file_write, id: id}, {:file_write, :ok}) do
    Protocol.encode_file_write_response(id)
  end

  defp encode_handler_response(
         %{kind: :terminal, id: id, method: "terminal/output"},
         {:terminal, {:ok, result}}
       )
       when is_map(result) do
    Protocol.encode_response(Map.put_new(result, "truncated", false), id)
  end

  defp encode_handler_response(%{kind: :terminal, id: id}, {:terminal, {:ok, result}}) do
    Protocol.encode_response(result, id)
  end

  defp encode_handler_response(%{kind: :mcp, id: id}, {:mcp, {:ok, result}}) do
    if Extensions.json?(result) do
      Protocol.encode_mcp_result(id, result)
    else
      Protocol.encode_error(-32603, "MCP provider unavailable", nil, id)
    end
  end

  defp encode_handler_response(%{kind: :mcp, id: id}, {:mcp, {:mcp_error, error}}) do
    if Mcp.mcp_error?(error) do
      Protocol.encode_mcp_error(id, error)
    else
      Protocol.encode_error(-32603, "MCP provider unavailable", nil, id)
    end
  end

  defp encode_handler_response(%{kind: :mcp, id: id}, {:mcp, {:error, reason}}) do
    Logger.warning("ACP MCP provider failed", reason: safe_error_class(reason))
    Protocol.encode_error(-32603, "MCP provider unavailable", nil, id)
  end

  defp encode_handler_response(%{kind: :mcp, id: id}, {:mcp, _outcome}) do
    Protocol.encode_error(-32603, "MCP provider unavailable", nil, id)
  end

  defp encode_handler_response(%{id: id}, {_kind, {:error, reason}}) do
    Logger.warning("ACP client handler failed", reason: safe_error_class(reason))
    Protocol.encode_error(-32603, "Client handler failed", nil, id)
  end

  defp encode_handler_response(%{id: id}, _unexpected) do
    Protocol.encode_error(-32603, "Client handler returned an invalid result", nil, id)
  end

  defp track_agent_request(state, ref, kind, id, session_id, extra \\ %{}) do
    timer_ref =
      Process.send_after(self(), {:agent_handler_timeout, ref}, state.handler_request_timeout)

    request =
      Map.merge(
        %{
          kind: kind,
          id: id,
          session_id: session_id,
          timer_ref: timer_ref,
          handler_gate: HandlerRunner.request_gate(ref)
        },
        extra
      )

    %{
      state
      | pending_agent_requests: PendingRequests.put(state.pending_agent_requests, ref, request)
    }
  end

  defp fail_pending_agent_requests(reason, state) do
    state =
      Enum.reduce(state.pending_agent_requests, state, fn {_ref, request}, state ->
        cancel_timer(request.timer_ref)
        stop_mcp_worker(request)
        response = Protocol.encode_error(-32603, reason, nil, request.id)
        send_to_transport(response, state)
        finish_mcp_request(state, request)
      end)

    %{state | pending_agent_requests: %{}}
  end

  defp cancel_pending_interactions(session_id, state) do
    {to_cancel, keep} =
      Enum.split_with(state.pending_agent_requests, fn {_ref, request} ->
        request.kind in [:permission, :elicitation] and request.session_id == session_id
      end)

    Enum.each(to_cancel, fn {_ref, request} ->
      cancel_timer(request.timer_ref)
      stop_mcp_worker(request)

      response =
        case request.kind do
          :permission ->
            Protocol.encode_permission_response(request.id, %{"outcome" => "cancelled"})

          :elicitation ->
            Protocol.encode_elicitation_response(request.id, %{"action" => "cancel"})

          _other ->
            Protocol.encode_request_cancelled_error(request.id)
        end

      send_to_transport(response, state)
    end)

    %{state | pending_agent_requests: Map.new(keep)}
  end

  defp handle_cancel_request_notification(%{"requestId" => request_id}, state) do
    {to_cancel, keep} =
      Enum.split_with(state.pending_agent_requests, fn {_ref, request} ->
        request.id == request_id
      end)

    state =
      Enum.reduce(to_cancel, state, fn {_ref, request}, state ->
        cancel_timer(request.timer_ref)
        stop_mcp_worker(request)
        response = Protocol.encode_request_cancelled_error(request.id)
        send_to_transport(response, state)
        finish_mcp_request(state, request)
      end)

    %{state | pending_agent_requests: Map.new(keep)}
  end

  defp handle_cancel_request_notification(_params, state), do: state

  defp safe_error_class({kind, reason, _stack}) when kind in [:error, :exit, :throw],
    do: "#{kind}:#{inspect(error_module(reason))}"

  defp safe_error_class(reason), do: inspect(error_module(reason))

  defp error_module(%{__struct__: module}) when is_atom(module), do: module
  defp error_module(_reason), do: :error

  defp update_mailbox_below_limits?(pid, count_limit, byte_limit, incoming_bytes, kind) do
    with {:message_queue_len, length} when length < count_limit <-
           Process.info(pid, :message_queue_len),
         {:messages, messages} when length(messages) < count_limit <-
           Process.info(pid, :messages) do
      queued_bytes = queued_update_bytes(messages, kind, byte_limit)
      incoming_bytes <= byte_limit - queued_bytes
    else
      _full_or_closed -> false
    end
  end

  defp queued_update_bytes(messages, kind, limit) do
    Enum.reduce_while(messages, 0, fn message, total ->
      total = total + queued_update_size(message, kind)
      if total >= limit, do: {:halt, total}, else: {:cont, total}
    end)
  end

  defp queued_update_size({:acp_session_update, _session_id, update}, :listener),
    do: :erlang.external_size(update)

  defp queued_update_size({:acp_extension_notification, _, _} = event, :listener),
    do: :erlang.external_size(event)

  defp queued_update_size(_message, _kind), do: 0

  defp cancel_pending_timer({_from, _tag, _monitor_ref, timer_ref}), do: cancel_timer(timer_ref)
  defp cancel_pending_timer(_pending), do: :ok

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer_ref), do: Process.cancel_timer(timer_ref, async: true, info: false)

  defp valid_utf8_prefix(_text, 0), do: ""

  defp valid_utf8_prefix(text, limit) when byte_size(text) <= limit, do: text

  defp valid_utf8_prefix(text, limit) do
    prefix = binary_part(text, 0, limit)
    trim_invalid_utf8_suffix(prefix)
  end

  defp trim_invalid_utf8_suffix(<<>>), do: ""

  defp trim_invalid_utf8_suffix(prefix) do
    if String.valid?(prefix) do
      prefix
    else
      trim_invalid_utf8_suffix(binary_part(prefix, 0, byte_size(prefix) - 1))
    end
  end

  defp session_roots(cwd, lifecycle_opts) do
    [cwd | LifecycleParams.additional_directories(lifecycle_opts) || []]
    |> Enum.map(&WorkspacePath.canonical/1)
    |> Enum.uniq()
  end

  defp path_within_roots?(path, roots) when is_binary(path) and is_list(roots) do
    Enum.any?(roots, &WorkspacePath.within?(path, &1))
  end

  defp path_within_roots?(_path, _roots), do: false

  defp refuse_handler_mcp(%{handler_pid: pid}) when is_pid(pid),
    do: Arbor.ACP.Client.HandlerRunner.refuse_mcp(pid)

  defp refuse_handler_mcp(_state), do: :ok

  defp do_disconnect(state) do
    refuse_handler_mcp(state)

    if state.transport_actor_monitor,
      do: Process.demonitor(state.transport_actor_monitor, [:flush])

    if state.receiver_pid && Process.alive?(state.receiver_pid) do
      Process.unlink(state.receiver_pid)
      Process.exit(state.receiver_pid, :shutdown)
    end

    cleanup = if state.transport_state, do: close_transport(state), else: :ok

    ConnectionScope.closed(
      state.connection_scope,
      remember_cleanup(state.cleanup_result, cleanup)
    )

    reply_all_pending({:error, :disconnected}, state)
    |> Map.merge(%{
      status: :disconnected,
      receiver_pid: nil,
      transport_state: nil,
      transport_actor_monitor: nil,
      cleanup_result: remember_cleanup(state.cleanup_result, cleanup)
    })
  end

  defp close_transport(state) do
    case state.transport_mod.close(state.transport_state) do
      :ok -> :ok
      {:error, _reason} = result -> result
      other -> {:error, {:invalid_close_result, LogSummary.describe(other)}}
    end
  catch
    :exit, {:noproc, _call} -> :ok
    kind, reason -> {:error, {:close_failed, kind, reason}}
  end

  defp open_mcp_session(encoder, from, state, telemetry_tag, lifecycle_opts, mcp_kind) do
    case gate_acp_servers(lifecycle_opts, state) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, lifecycle_opts, ids, omitted} ->
        message = encoder.(lifecycle_opts)

        case reserve_mcp(state, message["id"], mcp_kind, ids) do
          {:error, reason} ->
            {:reply, {:error, {:invalid_params, reason}}, state}

          {:ok, state} ->
            state = put_mcp_plan(state, message["id"], mcp_kind, ids, omitted)

            case send_request(message, from, state, telemetry_tag) do
              {:reply, {:error, _reason} = error, state} ->
                {:reply, error, abort_mcp_plan(state, message["id"])}

              other ->
                other
            end
        end
    end
  end

  defp gate_acp_servers(lifecycle_opts, state) do
    case LifecycleParams.select_acp_servers(
           LifecycleParams.mcp_servers(lifecycle_opts),
           state.agent_capabilities,
           state.mcp_providers
         ) do
      {:ok, %{servers: servers, server_ids: ids, omitted: omitted}} ->
        log_mcp_omissions(omitted)
        {:ok, Keyword.put(lifecycle_opts, :mcp_servers, servers), ids, omitted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp log_mcp_omissions([]), do: :ok

  defp log_mcp_omissions(omitted) do
    Enum.each(omitted, fn %{id: id, reason: reason} ->
      hash = LogSummary.fingerprint(id)

      Logger.info("ACP client omitted an MCP-over-ACP server",
        reason: reason,
        server_id_hash: hash
      )

      :telemetry.execute(
        [:arbor_acp, :mcp, :server, :omitted],
        %{count: 1},
        %{reason: reason, server_id_hash: hash}
      )
    end)
  end

  defp reserve_mcp(state, token, :new, ids) do
    case Mcp.begin_new(state.mcp, token, ids) do
      {:ok, mcp} -> {:ok, %{state | mcp: mcp}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reserve_mcp(state, token, {:existing, session_id}, ids) do
    case Mcp.begin_existing(state.mcp, session_id, token, ids) do
      {:ok, mcp} -> {:ok, %{state | mcp: mcp}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_mcp_plan(state, token, kind, ids, omitted) do
    plan = %{kind: kind, ids: ids, omitted: omitted}
    %{state | mcp_plans: Map.put(state.mcp_plans, token, plan)}
  end

  defp mcp_plan_omissions(state, token) do
    case Map.get(state.mcp_plans, token) do
      %{omitted: omitted} when is_list(omitted) -> omitted
      _missing -> []
    end
  end

  defp with_omitted_servers({:ok, result}, omitted) when is_map(result) and omitted != [] do
    reported =
      Enum.map(omitted, fn %{id: id, reason: reason} ->
        %{"serverId" => id, "reason" => Atom.to_string(reason)}
      end)

    {:ok, Map.put(result, "omittedMcpServers", reported)}
  end

  defp with_omitted_servers(reply, _omitted), do: reply

  defp abort_mcp_plan(state, token) do
    {plan, plans} = Map.pop(state.mcp_plans, token)
    state = %{state | mcp_plans: plans}
    if plan, do: abort_mcp_token(state, token), else: state
  end

  defp abort_mcp_token(state, token) do
    {mcp, dropped} = Mcp.abort(state.mcp, token)
    fail_mcp_entries(%{state | mcp: mcp}, dropped)
  end

  defp settle_mcp_plan(token, tag, reply, state) do
    {plan, plans} = Map.pop(state.mcp_plans, token)
    state = %{state | mcp_plans: plans}

    cond do
      plan == nil and success_close?(tag, reply) ->
        {reply, release_mcp_session(state, elem(tag, 1))}

      plan == nil ->
        {reply, state}

      match?({:ok, _result}, reply) and plan.kind == :new ->
        {reply, commit_mcp_new(state, token, reply, plan.ids)}

      match?({:ok, _result}, reply) and match?({:existing, _session_id}, plan.kind) ->
        {_kind, session_id} = plan.kind
        commit_mcp_existing(state, token, session_id, plan.ids, reply)

      true ->
        {reply, abort_mcp_token(state, token)}
    end
  end

  defp success_close?({kind, session_id}, {:ok, _result})
       when kind in [:close_session, :delete_session] and is_binary(session_id),
       do: true

  defp success_close?(_tag, _reply), do: false

  defp commit_mcp_new(state, token, {:ok, %{"sessionId" => session_id}}, ids)
       when is_binary(session_id) and session_id != "" do
    %{state | mcp: Mcp.commit_new(state.mcp, token, session_id, ids)}
  end

  defp commit_mcp_new(state, token, _reply, _ids), do: abort_mcp_token(state, token)

  defp commit_mcp_existing(state, token, session_id, ids, reply) do
    closed? = Mcp.token_closed?(state.mcp, session_id, token)
    {mcp, dropped} = Mcp.commit_existing(state.mcp, token, session_id, ids)
    state = fail_mcp_entries(%{state | mcp: mcp}, dropped)

    reply =
      if closed?,
        do: {:error, {:invalid_params, :mcp_server_id_in_use}},
        else: reply

    {reply, state}
  end

  defp release_mcp_session(state, session_id) do
    {mcp, dropped} = Mcp.release_session(state.mcp, session_id)
    fail_mcp_entries(%{state | mcp: mcp}, dropped)
  end

  defp fail_mcp_entries(state, entries) do
    Enum.reduce(entries, state, fn entry, state ->
      cancel_mcp_provider_work(state, entry)
    end)
  end

  defp cancel_mcp_provider_work(state, %{ref: ref, outer_id: outer_id}) when is_reference(ref) do
    case PendingRequests.pop(state.pending_agent_requests, ref) do
      {nil, pending} ->
        %{state | pending_agent_requests: pending}

      {request, pending} ->
        cancel_timer(request.timer_ref)
        stop_mcp_worker(request)
        send_to_transport(Protocol.encode_request_cancelled_error(outer_id), state)
        %{state | pending_agent_requests: pending}
    end
  end

  defp cancel_mcp_provider_work(state, _entry), do: state

  defp dispatch_mcp_message(params, id, state) do
    server_id = params["serverId"]

    case Mcp.session_id(state.mcp, server_id) do
      {:ok, session_id} ->
        if Map.has_key?(state.sessions, session_id) do
          accept_mcp_message(state, session_id, params, id)
        else
          send_agent_request_error(state, id, -32_602, "Unknown session")
        end

      _pending_or_missing ->
        send_agent_request_error(state, id, -32_602, "Unknown MCP server")
    end
  end

  defp accept_mcp_message(state, session_id, params, id) do
    server_id = params["serverId"]
    request_id = params["requestId"]
    provider = Map.get(state.mcp_providers, server_id)

    if provider_available?(provider, state) do
      ref = make_ref()

      entry = %{
        session_id: session_id,
        server_id: server_id,
        request_id: request_id,
        outer_id: id,
        ref: ref
      }

      case Mcp.track(state.mcp, entry, true) do
        {:ok, mcp} ->
          state = %{state | mcp: mcp}
          dispatch_provider(state, ref, provider, session_id, params)

          track_agent_request(state, ref, :mcp, id, session_id, %{
            server_id: server_id,
            request_id: request_id
          })

        {:error, :duplicate_request_id} ->
          send_agent_request_error(state, id, -32_600, "Request id is already in use")

        {:error, :too_many_pending_requests} ->
          send_agent_request_error(state, id, -32_000, "Too many pending requests")

        {:error, :unknown_mcp_server} ->
          send_agent_request_error(state, id, -32_602, "Unknown MCP server")
      end
    else
      send_agent_request_error(state, id, -32_603, "MCP provider unavailable")
    end
  end

  defp dispatch_provider(_state, ref, pid, session_id, params) when is_pid(pid) do
    send(pid, {:acp_mcp_request, ref, mcp_context(session_id, params, ref), params})
  end

  defp dispatch_provider(state, ref, provider, session_id, params) do
    HandlerRunner.mcp_request(
      state.handler_pid,
      ref,
      provider,
      mcp_context(session_id, params, ref),
      params
    )
  end

  defp mcp_context(session_id, params, token) do
    %{
      client: self(),
      session_id: session_id,
      server_id: params["serverId"],
      request_id: params["requestId"],
      token: token
    }
  end

  defp provider_available?(:handler, state) do
    is_pid(state.handler_pid) and
      function_exported?(state.handler_mod, :handle_mcp_request, 4)
  end

  defp provider_available?(module, state) when is_atom(module) do
    is_pid(state.handler_pid) and module_provider?(module)
  end

  defp provider_available?(pid, _state) when is_pid(pid), do: Process.alive?(pid)
  defp provider_available?(_provider, _state), do: false

  defp finish_mcp_request(state, %{kind: :mcp, server_id: server_id, request_id: request_id}) do
    {_entry, mcp} = Mcp.finish(state.mcp, server_id, request_id)
    %{state | mcp: mcp}
  end

  defp finish_mcp_request(state, _request), do: state

  defp fail_provider_requests(state, server_id) do
    {to_fail, keep} =
      Enum.split_with(state.pending_agent_requests, fn {_ref, request} ->
        request.kind == :mcp and request.server_id == server_id
      end)

    state =
      Enum.reduce(to_fail, state, fn {_ref, request}, state ->
        cancel_timer(request.timer_ref)
        stop_mcp_worker(request)

        send_to_transport(
          Protocol.encode_error(-32_603, "MCP provider unavailable", nil, request.id),
          state
        )

        finish_mcp_request(state, request)
      end)

    %{state | pending_agent_requests: Map.new(keep)}
  end

  defp normalize_provider_map(providers) when is_map(providers) do
    Enum.reduce_while(providers, {:ok, %{}}, fn {id, provider}, {:ok, acc} ->
      cond do
        not valid_server_id?(id) ->
          {:halt, {:error, {:invalid_params, :mcp_provider}}}

        true ->
          case normalize_provider(provider) do
            {:ok, provider} -> {:cont, {:ok, Map.put(acc, id, provider)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp normalize_provider_map(_providers), do: {:error, {:invalid_params, :mcp_provider}}

  defp normalize_provider(:handler), do: {:ok, :handler}

  defp normalize_provider(module) when is_atom(module) do
    if module_provider?(module),
      do: {:ok, module},
      else: {:error, {:invalid_params, :mcp_provider}}
  end

  defp normalize_provider(pid) when is_pid(pid) do
    if node(pid) == node() and Process.alive?(pid),
      do: {:ok, pid},
      else: {:error, {:invalid_params, :mcp_provider}}
  end

  defp normalize_provider(_provider), do: {:error, {:invalid_params, :mcp_provider}}

  defp module_provider?(module) when module in [nil, true, false], do: false

  defp module_provider?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :handle_mcp_request, 2)
  end

  defp put_provider(state, server_id, provider) do
    monitors =
      if is_pid(provider) do
        Map.put(state.mcp_provider_monitors, Process.monitor(provider), server_id)
      else
        state.mcp_provider_monitors
      end

    %{
      state
      | mcp_providers: Map.put(state.mcp_providers, server_id, provider),
        mcp_provider_monitors: monitors
    }
  end

  defp drop_provider_monitor(state, server_id) do
    case Enum.find(state.mcp_provider_monitors, fn {_ref, id} -> id == server_id end) do
      {ref, ^server_id} ->
        Process.demonitor(ref, [:flush])
        %{state | mcp_provider_monitors: Map.delete(state.mcp_provider_monitors, ref)}

      nil ->
        state
    end
  end

  defp mcp_server_in_use?(state, server_id) do
    Mcp.session_id(state.mcp, server_id) != :error
  end

  defp valid_server_id?(id), do: is_binary(id) and String.valid?(id)

  defp notify_token(nil), do: :ok
  defp notify_token(token) when is_reference(token), do: :ok
  defp notify_token(_token), do: {:error, :invalid_params}

  defp notify_session(nil), do: :ok

  defp notify_session(session_id) when is_binary(session_id) do
    if String.valid?(session_id), do: :ok, else: {:error, :invalid_params}
  end

  defp notify_session(_session_id), do: {:error, :invalid_params}

  defp stop_mcp_worker(request) do
    if gate = Map.get(request, :handler_gate), do: :atomics.put(gate, 1, 0)
    if is_pid(Map.get(request, :worker)), do: Process.exit(request.worker, :kill)
    :ok
  end

  defp json_object_option(nil), do: :ok

  defp json_object_option(value) when is_map(value) do
    if Extensions.json?(value), do: :ok, else: {:error, :invalid_params}
  end

  defp json_object_option(_value), do: {:error, :invalid_params}

  defp terminal_cleanup({:cleanup_failed, _reason, {:error, _} = result}), do: result
  defp terminal_cleanup({:connection_error, reason}), do: terminal_cleanup(reason)
  defp terminal_cleanup({:transport_error, reason}), do: terminal_cleanup(reason)
  defp terminal_cleanup({:transport_closed, reason}), do: terminal_cleanup(reason)
  defp terminal_cleanup(_reason), do: :ok
  defp remember_cleanup({:error, _} = previous, _result), do: previous
  defp remember_cleanup(:ok, result), do: result
end
