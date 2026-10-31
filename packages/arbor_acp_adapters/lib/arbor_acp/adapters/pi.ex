defmodule Arbor.ACP.Adapters.Pi do
  @moduledoc """
  ACP adapter for the Pi coding agent.

  The adapter translates ACP JSON-RPC to Pi's RPC NDJSON protocol. In bridge
  mode it owns a shared subprocess handle so a fresh Pi process can be
  attached to each loaded or resumed ACP session.

  Workspace `.pi` settings, prompts, skills, packages and `AGENTS.md` are
  ignored unless `:trust_workspace_config` is set. By default the child also
  gets a private per-session `PI_CODING_AGENT_DIR`, `--no-context-files` and
  `--no-approve`; inherited `PI_CODING_AGENT_DIR` is ignored and a workspace
  `pi` executable is refused. Pass `:agent_dir` to keep a specific directory.

  Managed output uses one frame of shared delivery credit. Startup banners
  retained for session metadata are limited by `:max_prelude_lines` (64) and
  `:max_prelude_bytes` (65,536); exceeding either limit fails pending work.
  """

  @behaviour Arbor.ACP.Adapter

  @impl true
  def name, do: "pi"

  require Logger

  alias Arbor.ACP.AdapterSupport.Subprocess, as: PortRunner
  alias Arbor.ACP.AdapterSupport.WorkspacePath
  alias Arbor.RPC.{Framing, Subprocess}

  alias Arbor.ACP.Adapters.Pi.Config
  alias Arbor.ACP.Adapters.Pi.Events
  alias Arbor.ACP.Adapters.Pi.Prompt
  alias Arbor.ACP.Adapters.Pi.PromptFlow
  alias Arbor.ACP.Adapters.Pi.RPC
  alias Arbor.ACP.Adapters.Pi.Sessions
  alias Arbor.ACP.Adapters.Pi.SessionStore
  alias Arbor.ACP.Adapters.Pi.Settings
  alias Arbor.ACP.Adapters.Pi.SlashCommands
  alias Arbor.ACP.Adapters.Pi.Startup
  alias Arbor.ACP.Adapters.Pi.Tools

  alias Arbor.ACP.AdapterEvents
  alias Arbor.RPC.JSONRPC, as: Envelope
  alias Arbor.ACP.Adapters.Internal.PromptQueue
  alias Arbor.ACP.Adapters.Internal.RuntimeHome
  alias Arbor.ACP.Types

  @auth_method_id "pi_terminal_login"

  defstruct [
    :session_id,
    :session_file,
    :session_dir,
    :session_map_path,
    :cwd,
    :thinking_level,
    :current_model_id,
    :port,
    :port_monitor,
    :framing,
    :subprocess_error,
    cleanup_result: :ok,
    home_cleanup_error: nil,
    auth_home_cleanup_error: nil,
    opts: [],
    auth_home_opts: [],
    managed?: true,
    delete_session_files?: false,
    available_models: [],
    available_thinking_levels: [],
    file_commands: [],
    available_commands: [],
    text_acc: [],
    buffer: "",
    prelude_lines: [],
    startup_sent?: false,
    last_session_cwd: nil,
    # Host-authorized session cwd; never derived from what the agent reports.
    workspace_root: nil,
    settings: %{},
    pending_prompt: nil,
    # A prompt a session change or close answered as cancelled while its Pi
    # turn still runs; the next prompt waits until that turn settles.
    aborted_turn: nil,
    prompt_queue: PromptQueue.new(),
    active_tool_executions: %{},
    current_tool_calls: %{},
    edit_snapshots: %{},
    pending_extension_ui: %{},
    # The extension request the latest client response (or its cancel)
    # answered, so a write that fails can be replaced; see
    # outbound_write_failed/3.
    answered_ui: nil,
    last_usage: %{},
    # Pi requests that read or change the session run as serialized
    # operations, one in flight and the rest queued (see "Serialized Pi
    # operations").
    op_in_flight: nil,
    op_queue: [],
    # Set when Pi could not return to the session the adapter serves.
    desynced: nil,
    pending_controls: %{},
    control_groups: %{},
    msg_counter: 0,
    rpc_counter: 0
  ]

  @impl true
  def environment_defaults(opts), do: Arbor.ACP.Adapters.Internal.Environment.pi(opts)

  @impl true
  def env(opts) do
    %{}
    |> RuntimeHome.put(opts, :pi)
    |> maybe_put_session_dir(opts)
  end

  @impl true
  def init(opts) do
    opts = RuntimeHome.put_opt(opts, :pi)

    {:ok,
     %__MODULE__{
       opts: opts,
       auth_home_opts: opts,
       managed?: Keyword.get(opts, :managed, true),
       delete_session_files?: Keyword.get(opts, :delete_session_files, false),
       thinking_level: Keyword.get(opts, :thinking_level, Config.default_thinking_level()),
       session_dir: session_dir(opts),
       session_map_path: Keyword.get(opts, :session_map_path, SessionStore.default_map_path()),
       cwd: Keyword.get(opts, :cwd),
       workspace_root: Keyword.get(opts, :cwd),
       last_session_cwd: Keyword.get(opts, :cwd)
     }}
  end

  @impl true
  def command(_opts), do: :adapter_managed

  @doc false
  def cli_command(opts) do
    settings = Settings.load(Keyword.get(opts, :cwd), opts)
    cli_path = Settings.pi_command(opts, settings)

    with {:ok, cli_path} <- reject_workspace_cli(cli_path, opts),
         {:ok, args} <- append_opt(rpc_args(opts), opts, :session_path, "--session") do
      {cli_path, args}
    end
  end

  @impl true
  def capabilities do
    %{
      "loadSession" => true,
      "mcpCapabilities" => %{"http" => false, "sse" => false},
      "promptCapabilities" => %{
        "image" => true,
        "audio" => false,
        "embeddedContext" => System.get_env("PI_ACP_ENABLE_EMBEDDED_CONTEXT") == "true"
      },
      "_meta" => %{
        "ex_mcp" => %{
          "pi" => %{
            "sessionStore" => SessionStore.default_map_path(),
            "thinkingLevels" => Config.thinking_levels(),
            "features" => %{
              "slashCommands" => true,
              "terminalAuth" => true,
              "modelSelection" => true,
              "sessionLoad" => true,
              "sessionResume" => true,
              "sessionClose" => true,
              "sessionDelete" => true,
              "structuredDiffs" => true
            }
          }
        }
      }
    }
    |> put_in(["sessionCapabilities"], %{
      "list" => %{},
      "resume" => %{},
      "close" => %{},
      "delete" => %{}
    })
  end

  @impl true
  def auth_methods(opts, %{auth_home_opts: state_opts}) when is_list(state_opts) do
    auth_methods(Keyword.merge(opts, state_opts))
  end

  def auth_methods(opts, _state), do: auth_methods(opts)

  @impl true
  def auth_methods(opts) do
    settings = Settings.load(Keyword.get(opts, :cwd), opts)
    command = Settings.pi_command(opts, settings)
    env = terminal_home_env(opts)

    [
      %{
        "id" => @auth_method_id,
        "name" => "Launch pi in the terminal",
        "description" => "Start pi interactively to configure API keys or login",
        "type" => "terminal",
        "args" => [],
        "env" => env,
        "_meta" => %{
          "terminal-auth" => %{
            "command" => command,
            "args" => [],
            "label" => "Launch pi",
            "env" => env
          }
        }
      }
    ]
  end

  @impl true
  def modes, do: Config.modes()

  @impl true
  def config_options do
    Config.session_config_options(nil, Config.thinking_state(%{}))
  end

  @impl true
  def list_sessions(params, state) do
    all_sessions =
      SessionStore.list_pi_sessions(
        session_dir: state.session_dir,
        agent_dir: Keyword.get(state.opts, :agent_dir)
      )

    {sessions, next_cursor} =
      Sessions.page(
        all_sessions,
        params["cwd"] || state.last_session_cwd,
        params["cursor"] || "0"
      )

    {:ok, RPC.compact(%{"sessions" => sessions, "nextCursor" => next_cursor, "_meta" => %{}}),
     state}
  end

  @impl true
  def translate_outbound(%{"method" => "initialize"}, state), do: {:ok, :skip, state}

  def translate_outbound(%{"method" => "authenticate"}, state) do
    case RuntimeHome.refresh_auth(state.auth_home_opts, state.opts, :pi) do
      :ok -> {:reply, %{}, state}
      {:error, reason} -> {:error, inspect(reason), state}
    end
  end

  def translate_outbound(%{"method" => "session/new", "id" => acp_id, "params" => params}, state) do
    cwd = params["cwd"] || state.workspace_root || Keyword.get(state.opts, :cwd) || File.cwd!()

    case Sessions.require_absolute_cwd(cwd) do
      :ok -> begin_session_setup({:new, acp_id, cwd}, state)
      {:error, reason} -> {:error, reason, state}
    end
  end

  def translate_outbound(%{"method" => "session/load", "id" => acp_id, "params" => params}, state) do
    plan_session_switch(acp_id, params, true, state)
  end

  def translate_outbound(
        %{"method" => "session/resume", "id" => acp_id, "params" => params},
        state
      ) do
    plan_session_switch(acp_id, params, false, state)
  end

  def translate_outbound(
        %{"method" => "session/prompt", "id" => acp_id, "params" => params},
        state
      ) do
    with :ok <- check_synced(state),
         :ok <- check_no_session_change(state) do
      {message, images} = Prompt.to_pi_message(params["prompt"])
      translate_prompt_message(message, images, acp_id, params, state)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def translate_outbound(%{"method" => "session/cancel"}, state) do
    had_queued = not PromptQueue.empty?(state.prompt_queue)
    {queued_responses, state} = PromptFlow.cancel_queued(state)
    state = PromptFlow.mark_cancel_requested(state)
    messages = queued_responses ++ PromptFlow.queue_cleared_messages(state, had_queued)
    abort = RPC.encode_notification(RPC.method(:abort))

    # The queued prompts are answered whether or not Pi gets the abort.
    if state.managed? do
      _ = write_managed(abort, state)
      {:messages, messages, state}
    else
      {:messages_and_write, messages, abort, state}
    end
  end

  def translate_outbound(%{"method" => "session/close", "params" => params}, state) do
    session_id = params["sessionId"]

    {messages, abort, state} =
      if is_nil(session_id) or session_id == state.session_id do
        close_session(state)
      else
        {[], nil, state}
      end

    state |> cleanup_reply() |> with_reply_extras(messages, abort) |> advance_after_reply()
  end

  def translate_outbound(%{"method" => "session/delete", "params" => params}, state) do
    session_id = params["sessionId"]
    current? = is_nil(session_id) or session_id == state.session_id
    # Only the current session falls back to the file the adapter knows.
    current_file = if current?, do: %{"sessionFile" => state.session_file}

    {messages, abort, state} =
      if current?, do: close_session(state), else: {[], nil, state}

    case state.cleanup_result do
      :ok ->
        entry =
          if is_binary(session_id), do: SessionStore.delete(state.session_map_path, session_id)

        maybe_delete_session_file(state, entry || current_file || %{})
        {:reply, %{}, state} |> with_reply_extras(messages, abort) |> advance_after_reply()

      {:error, reason} ->
        {:error, inspect(reason), state}
    end
  end

  def translate_outbound(%{"method" => "session/set_mode", "params" => params}, state) do
    mode = params["modeId"]

    with :ok <- check_synced(state),
         {:ok, messages, data, state} <-
           Config.set_thinking_plan(mode, params["sessionId"], state) do
      deliver_messages_and_ack(messages, data, override_refresh_level(state))
    else
      {:error, reason} -> {:error, reason, state}
      :error -> {:error, "Unknown modeId: #{inspect(mode)}", state}
    end
  end

  def translate_outbound(%{"method" => "session/set_model", "params" => params} = message, state) do
    translate_set_model(params["modelId"], params["sessionId"], message["id"], state)
  end

  def translate_outbound(
        %{"method" => "session/set_config_option", "params" => params} = message,
        state
      ) do
    case check_synced(state) do
      :ok -> translate_config_option(params["configId"], params["value"], message["id"], state)
      {:error, reason} -> {:error, reason, state}
    end
  end

  def translate_outbound(%{"id" => acp_id, "result" => result}, state) do
    resolve_extension_ui_response(acp_id, result, state)
  end

  def translate_outbound(%{"id" => acp_id, "error" => _error}, state) do
    resolve_extension_ui_response(acp_id, %{"action" => "cancel"}, state)
  end

  def translate_outbound(
        %{"method" => "$/cancel_request", "params" => %{"requestId" => acp_id}},
        state
      ) do
    {cancelled, waiting} = Enum.split_with(state.op_queue, &queued_setup?(&1, acp_id))

    cond do
      cancelled != [] ->
        error = Envelope.error(acp_id, -32_800, "Request cancelled")
        {:messages, [error], %{state | op_queue: waiting}}

      running_setup?(state.op_in_flight, acp_id) ->
        cancel_session_setup(state.op_in_flight, state)

      true ->
        resolve_extension_ui_response(acp_id, %{"action" => "cancel"}, state)
    end
  end

  def translate_outbound(%{"method" => method}, state) do
    if String.starts_with?(method, "_ex_mcp.pi/") or String.starts_with?(method, "pi/") do
      {:error, "Pi extension methods were removed; use ACP session methods or slash commands",
       state}
    else
      {:ok, :skip, state}
    end
  end

  # Unmanaged, the consumer writes what translate_outbound/2 returns. When that
  # write fails the request is answered with the error, so nothing it started
  # is tracked any more: Pi never received it.
  # Only requests start prompts, commands, setups and model switches; a
  # client's response to a Pi extension request is never retired, even when
  # its id equals one of the client's requests.
  @impl true
  def outbound_write_failed(%{"id" => acp_id, "method" => _method}, _reason, state) do
    state
    |> retire_prompt(acp_id)
    |> retire_prompt_commands(acp_id)
    |> retire_setup(acp_id)
    |> retire_model_switch(acp_id)
  end

  def outbound_write_failed(
        %{"method" => "$/cancel_request", "params" => %{"requestId" => cancelled}},
        reason,
        state
      ),
      do: cancelled |> retire_switch_back(reason, state) |> replace_ui_answer(cancelled)

  # A client's answer to a Pi extension dialog: Pi is still waiting for it.
  def outbound_write_failed(%{"id" => acp_id} = message, _reason, state)
      when not is_map_key(message, "method"),
      do: replace_ui_answer(state, acp_id)

  def outbound_write_failed(_message, _reason, state), do: state

  # A cancel, which is small, takes the place of the answer that could not be
  # written; if it cannot be written either, the bridge closes Pi.
  defp replace_ui_answer(%{answered_ui: %{acp_id: acp_id, pi_id: pi_id}} = state, acp_id),
    do: {:write, RPC.line(cancelled_extension_ui_response(pi_id)), %{state | answered_ui: nil}}

  defp replace_ui_answer(state, _acp_id), do: state

  defp retire_prompt(%{pending_prompt: %{acp_id: acp_id}} = state, acp_id),
    do: %{state | pending_prompt: nil, text_acc: []}

  defp retire_prompt(state, _acp_id), do: state

  defp retire_prompt_commands(state, acp_id) do
    state.control_groups
    |> Map.values()
    |> Enum.filter(&(&1.acp_id == acp_id and &1.type not in [:session_new, :session_load]))
    |> Enum.reduce(state, &delete_group(&2, &1))
  end

  # Pi never received the change, so it stays on the previous session.
  defp retire_setup(state, acp_id) do
    state =
      case state.op_in_flight do
        %{type: :setup, acp_id: ^acp_id} = op ->
          group = running_setup_group(state)
          state = if group, do: delete_group(state, group), else: state
          %{Map.merge(state, op.previous.fields) | op_in_flight: nil}

        _op ->
          state
      end

    %{state | op_queue: Enum.reject(state.op_queue, &queued_setup?(&1, acp_id))}
  end

  defp retire_model_switch(
         %{op_in_flight: %{type: :model_switch, phase: :set_model, acp_id: acp_id}} = state,
         acp_id
       ),
       do: %{state | op_in_flight: nil}

  defp retire_model_switch(state, _acp_id), do: state

  # The cancel's switch back never reached Pi, which stays on the session the
  # cancelled setup changed to.
  defp retire_switch_back(
         cancelled,
         reason,
         %{op_in_flight: %{type: :switch_back, cancelled_request: cancelled} = op} = state
       ),
       do: desync(%{state | op_in_flight: nil}, op.previous.session_id, {:write_failed, reason})

  defp retire_switch_back(_cancelled, _reason, state), do: state

  @impl true
  def translate_inbound(line, state) do
    case RPC.decode_line(line) do
      :unknown ->
        {:skip, state}

      {:response, _id, {_status, event}} ->
        process_event(event, state)

      {:event, _type, event} ->
        process_event(event, state)
    end
  end

  @impl true
  def subprocess_receipt(message, state) do
    case PortRunner.event(state.port, message) do
      {:frame, token, _bytes} -> {state.port, token}
      _ -> nil
    end
  end

  @impl true
  def handle_adapter_message({:arbor_rpc, _generation, _event} = message, state) do
    case PortRunner.event(state.port, message) do
      {:frame, _token, line} -> managed_lines([line], state)
      {:closed, reason, remainder} -> managed_closed(state, exit_reason(reason), remainder)
      :ignore -> {:skip, state}
    end
  end

  def handle_adapter_message(
        {:DOWN, monitor, :process, _pid, reason},
        %{port_monitor: monitor} = state
      )
      when is_reference(monitor) do
    managed_closed(state, {:actor_down, reason}, "")
  end

  # Unmanaged callback consumers own their input transport. Keep this byte
  # adapter for existing direct consumers, bounded by the same shared decoder.
  def handle_adapter_message({port, {:data, data}}, %{port: port, managed?: false} = state) do
    decoder = state.framing || Framing.new(max_frame_bytes: max_frame_bytes(state))

    case Framing.push(decoder, data) do
      {:ok, lines, decoder} ->
        managed_lines(lines, %{state | framing: decoder, buffer: Framing.remainder(decoder)})

      {:error, reason} ->
        managed_closed(state, reason, "")
    end
  end

  def handle_adapter_message(
        {port, {:exit_status, code}},
        %{port: port, managed?: false} = state
      ),
      do: managed_closed(state, code, state.buffer)

  def handle_adapter_message({port, :closed}, %{port: port, managed?: false} = state),
    do: managed_closed(state, :closed, state.buffer)

  def handle_adapter_message(_message, state), do: {:skip, state}

  defp managed_lines(lines, state) do
    port = state.port

    {messages, state} =
      Enum.reduce_while(lines, {[], state}, fn line, {messages, acc} ->
        case line
             |> translate_inbound_or_prelude(acc)
             |> normalize_managed_inbound(port) do
          {:skip, state} ->
            {:cont, {messages, state}}

          {:messages, emitted, state} ->
            result = {Enum.reverse(emitted, messages), state}
            if state.subprocess_error, do: {:halt, result}, else: {:cont, result}
        end
      end)

    case messages do
      [] -> {:skip, state}
      messages -> {:messages, Enum.reverse(messages), state}
    end
  end

  defp managed_closed(state, reason, remainder) do
    {messages, state} = flush_managed_buffer(%{state | buffer: remainder}, state.port)
    messages = messages ++ pending_exit_messages(state, reason)
    demonitor_port(state)

    cleanup =
      state.cleanup_result
      |> remember_cleanup(terminal_cleanup(reason))
      |> remember_cleanup(close_owned_child(state))

    state = %{
      state
      | port: nil,
        port_monitor: nil,
        buffer: "",
        framing: nil,
        cleanup_result: cleanup
    }

    state = %{clear_pending_runtime_state(state) | op_queue: [], desynced: nil}
    state = release_stopped_home(state)

    if messages == [], do: {:skip, state}, else: {:messages, messages, state}
  end

  defp exit_reason({:exit_status, code}), do: code
  defp exit_reason(reason), do: reason

  defp terminal_cleanup({:cleanup_failed, _reason, result}), do: result
  defp terminal_cleanup(_reason), do: :ok
  defp remember_cleanup({:error, _reason} = previous, _result), do: previous
  defp remember_cleanup(:ok, result), do: result

  defp close_owned_child(%{managed?: true, port: port}) when not is_nil(port),
    do: PortRunner.close(port)

  defp close_owned_child(_state), do: :ok
  defp max_frame_bytes(state), do: Keyword.get(state.opts, :max_frame_bytes, 1_048_576)

  defp demonitor_port(%{port_monitor: monitor}) when is_reference(monitor),
    do: Process.demonitor(monitor, [:flush])

  defp demonitor_port(_state), do: :ok

  @impl true
  def shutdown(state) do
    state = state |> close_active_session() |> release_stopped_home()

    state =
      if state.managed? and
           (state.cleanup_result == :ok or
              (state.auth_home_cleanup_error != nil and
                 state.cleanup_result == {:error, state.auth_home_cleanup_error})) do
        case RuntimeHome.release(state.auth_home_opts, :pi) do
          :ok ->
            %{state | cleanup_result: :ok, auth_home_cleanup_error: nil}

          {:error, reason} ->
            %{state | cleanup_result: {:error, reason}, auth_home_cleanup_error: reason}
        end
      else
        state
      end

    case state.cleanup_result do
      {:error, reason} -> {:error, reason, state}
      :ok -> state
    end
  end

  defp prepare_session_process(cwd, _session_file, %{managed?: false} = state) do
    opts = session_runtime_opts(state.opts, cwd)
    settings = Settings.load(cwd, opts)

    {:ok,
     %{
       state
       | opts: opts,
         cwd: cwd,
         workspace_root: cwd,
         settings: settings,
         last_session_cwd: cwd,
         startup_sent?: false,
         prelude_lines: []
     }}
  end

  defp prepare_session_process(cwd, session_file, state) do
    state = close_active_session(state)

    case state.cleanup_result do
      :ok -> allocate_session_process(cwd, session_file, state)
      {:error, reason} -> {:error, inspect(reason), state}
    end
  end

  defp allocate_session_process(cwd, session_file, state) do
    session_key = "pi-child-#{System.unique_integer([:positive, :monotonic])}"

    opts =
      session_runtime_opts(
        Keyword.put(state.auth_home_opts, :_runtime_home_session, session_key),
        cwd
      )

    settings = Settings.load(cwd, opts)

    state =
      state
      |> Map.merge(%{
        opts: opts,
        cwd: cwd,
        workspace_root: cwd,
        settings: settings,
        last_session_cwd: cwd,
        startup_sent?: false,
        prelude_lines: []
      })

    case state.cleanup_result do
      :ok ->
        launch_opts = maybe_keyword_put(opts, :session_path, session_file)

        with :ok <- RuntimeHome.seed_auth(state.auth_home_opts, launch_opts, :pi),
             {cmd, args} when is_binary(cmd) <- cli_command(launch_opts) do
          case open_session_process(cmd, args, launch_opts, state) do
            {:error, reason, failed} -> {:error, reason, release_stopped_home(failed)}
            result -> result
          end
        else
          {:error, reason} -> {:error, inspect(reason), release_stopped_home(state)}
        end

      {:error, reason} ->
        {:error, inspect(reason), state}
    end
  end

  defp session_runtime_opts(opts, cwd) do
    opts
    |> Keyword.put(:cwd, cwd)
    |> RuntimeHome.put_opt(:pi)
  end

  @closed_during_setup "The session was closed before this session setup completed"

  # Closing a session answers its running and queued prompts and running
  # prompt commands as cancelled, so none waits for its timeout; an unmanaged
  # Pi, which keeps running, is asked to abort. A managed close also ends the
  # Pi process and the operation in flight with it: a running setup is
  # answered with an error, queued model work was for the closed session, and
  # waiting setups start next. An unmanaged consumer's Pi process outlives
  # the session, so the operation in flight, and a running setup's group,
  # still get their replies.
  defp close_session(state) do
    {messages, abort, state} = end_session(state)
    state = release_stopped_home(state)
    # The client closed the session, so nothing is published for it any more:
    # an operation still in flight finds its session gone.
    {messages, abort, %{state | session_id: nil, session_file: nil}}
  end

  defp end_session(%{managed?: false} = state) do
    {cancelled, abort?, state} = cancel_session_prompts(state)
    {abort, state} = abort_running_prompt(abort?, state)
    {cancelled, abort, keep_operation_across_close(state)}
  end

  defp end_session(state) do
    {cancelled, _abort?, state} = cancel_session_prompts(state)

    setup_errors =
      case state.op_in_flight do
        %{type: :setup, acp_id: acp_id} = op ->
          if Map.get(op, :cancelled?, false),
            do: [],
            else: [Envelope.error(acp_id, -32_603, @closed_during_setup)]

        _op ->
          []
      end

    state = close_active_session(state)

    {cancelled ++ setup_errors, nil,
     %{state | op_queue: Enum.filter(state.op_queue, &(&1.type == :setup))}}
  end

  defp keep_operation_across_close(state) do
    in_flight = state.op_in_flight
    aborted_turn = state.aborted_turn
    group = running_setup_group(state)
    refs = if group, do: MapSet.to_list(group.refs), else: []
    controls = Map.take(state.pending_controls, refs)
    state = close_active_session(state)

    state = %{
      state
      | op_in_flight: in_flight,
        aborted_turn: aborted_turn,
        pending_controls: Map.merge(state.pending_controls, controls)
    }

    if group,
      do: %{state | control_groups: Map.put(state.control_groups, group.group_id, group)},
      else: state
  end

  defp with_reply_extras({:reply, result, state}, [], nil), do: {:reply, result, state}

  defp with_reply_extras({:reply, result, state}, messages, nil),
    do: {:messages_and_reply, messages, result, state}

  defp with_reply_extras({:reply, result, state}, [], data),
    do: {:reply_and_write, result, data, state}

  defp with_reply_extras({:reply, result, state}, messages, data),
    do: {:messages_and_reply_and_write, messages, result, data, state}

  defp with_reply_extras(result, _messages, _data), do: result

  defp close_active_session(%{port: nil} = state) do
    demonitor_port(state)

    clear_pending_runtime_state(%{
      state
      | buffer: "",
        framing: nil,
        port_monitor: nil,
        prelude_lines: []
    })
  end

  defp close_active_session(state) do
    result = remember_cleanup(state.cleanup_result, close_owned_child(state))
    demonitor_port(state)
    error = if result == :ok, do: nil, else: result

    clear_pending_runtime_state(%{
      state
      | port: nil,
        port_monitor: nil,
        framing: nil,
        buffer: "",
        prelude_lines: [],
        subprocess_error: error,
        cleanup_result: result
    })
    |> release_stopped_home()
  end

  # Unmanaged input consumers keep their child alive across ACP close. Its
  # home remains until the owner exits; the RuntimeHome owner monitor then
  # removes it. Managed homes can go only after confirmed child cleanup.
  defp release_stopped_home(%{managed?: true, port: nil} = state) do
    if state.cleanup_result == :ok or
         (state.home_cleanup_error != nil and
            state.cleanup_result == {:error, state.home_cleanup_error}) do
      case RuntimeHome.release_opt(state.opts, :pi) do
        {:error, reason} ->
          %{state | cleanup_result: {:error, reason}, home_cleanup_error: reason}

        opts ->
          %{state | opts: opts, cleanup_result: :ok, home_cleanup_error: nil}
      end
    else
      state
    end
  end

  defp release_stopped_home(state), do: state

  defp clear_pending_runtime_state(state) do
    %{
      state
      | pending_prompt: nil,
        aborted_turn: nil,
        prompt_queue: PromptQueue.new(),
        text_acc: [],
        pending_controls: %{},
        control_groups: %{},
        active_tool_executions: %{},
        current_tool_calls: %{},
        edit_snapshots: %{},
        pending_extension_ui: %{},
        last_usage: %{},
        op_in_flight: nil
    }
  end

  defp cleanup_reply(%{cleanup_result: :ok} = state), do: {:reply, %{}, state}

  defp cleanup_reply(%{cleanup_result: {:error, reason}} = state),
    do: {:error, inspect(reason), state}

  defp deliver_pending(data, %{managed?: false} = state), do: {:ok, data, state}

  defp deliver_pending(data, state) do
    case write_managed(data, state) do
      :ok -> {:ok, :pending, state}
      {:error, reason} -> {:error, inspect(reason), state}
    end
  end

  defp deliver_ack(data, %{managed?: false} = state), do: {:ok, data, state}

  defp deliver_ack(data, state) do
    case write_managed(data, state) do
      :ok -> {:reply, %{}, state}
      {:error, reason} -> {:error, inspect(reason), state}
    end
  end

  defp deliver_messages_and_ack(messages, data, %{managed?: false} = state),
    do: {:messages_and_write, messages, data, state}

  defp deliver_messages_and_ack(messages, data, state) do
    case write_managed(data, state) do
      :ok -> {:messages_and_reply, messages, %{}, state}
      {:error, reason} -> {:error, inspect(reason), state}
    end
  end

  defp deliver_messages_and_config_result(messages, data, %{managed?: false} = state),
    do: {:messages_and_write, messages, data, state}

  # A switch that waits behind another one has nothing to write yet.
  defp deliver_messages_and_config_result(messages, "", state) do
    {:messages_and_reply, messages,
     %{"configOptions" => Config.confirmation_config_options_for_state(state)}, state}
  end

  defp deliver_messages_and_config_result(messages, data, state) do
    case write_managed(data, state) do
      :ok ->
        {:messages_and_reply, messages,
         %{"configOptions" => Config.confirmation_config_options_for_state(state)}, state}

      {:error, reason} ->
        {:error, inspect(reason), state}
    end
  end

  defp write_managed(_data, %{port: nil}), do: {:error, :no_active_pi_session}

  defp write_managed(data, %{port: port}) do
    case PortRunner.command(port, data) do
      {:error, :closed} -> {:error, :badarg}
      result -> result
    end
  end

  defp translate_inbound_or_prelude(line, state) do
    case translate_inbound(line, state) do
      {:skip, state} ->
        trimmed = String.trim(line)

        if trimmed == "" or String.starts_with?(trimmed, "{") do
          {:skip, state}
        else
          count = length(state.prelude_lines) + 1
          bytes = byte_size(trimmed) + Enum.reduce(state.prelude_lines, 0, &(byte_size(&1) + &2))

          if count > Keyword.get(state.opts, :max_prelude_lines, 64) or
               bytes > Keyword.get(state.opts, :max_prelude_bytes, 65_536) do
            fail_managed_input(state, {:prelude_overflow, count, bytes})
          else
            {:skip, %{state | prelude_lines: state.prelude_lines ++ [trimmed]}}
          end
        end

      result ->
        result
    end
  end

  defp normalize_managed_inbound({:messages, messages, state}, _port),
    do: {:messages, messages, state}

  defp normalize_managed_inbound({:messages_and_write, messages, data, state}, port) do
    managed_followup(messages, data, port, state)
  end

  defp normalize_managed_inbound({:skip_and_write, data, state}, port) do
    managed_followup([], data, port, state)
  end

  defp normalize_managed_inbound({:skip, state}, _port), do: {:skip, state}

  defp managed_followup(messages, _data, _port, %{managed?: false} = state),
    do: inbound_messages(messages, state)

  defp managed_followup(messages, data, port, state) do
    case PortRunner.command(port, data) do
      :ok ->
        inbound_messages(messages, state)

      {:error, reason} ->
        {:messages, failure_messages, state} = fail_managed_input(state, {:write_failed, reason})
        inbound_messages(messages ++ failure_messages, state)
    end
  end

  defp fail_managed_input(state, reason) do
    messages = pending_exit_messages(state, reason)
    state = close_active_session(state)

    {:messages, messages, %{state | subprocess_error: {:error, reason}, op_queue: []}}
  end

  defp inbound_messages([], state), do: {:skip, state}
  defp inbound_messages(messages, state), do: {:messages, messages, state}

  defp flush_managed_buffer(%{buffer: ""} = state, _port), do: {[], state}

  defp flush_managed_buffer(%{buffer: buffer} = state, port) do
    case buffer
         |> translate_inbound_or_prelude(%{state | buffer: ""})
         |> normalize_managed_inbound(port) do
      {:skip, state} -> {[], state}
      {:messages, messages, state} -> {messages, state}
    end
  end

  defp pending_exit_messages(state, reason) do
    prompt_messages =
      case state.pending_prompt do
        %{acp_id: acp_id} ->
          [Envelope.error(acp_id, -32_603, "Pi process exited: #{inspect(reason)}")]

        _ ->
          []
      end

    control_messages =
      state.control_groups
      |> Map.values()
      |> Enum.sort_by(& &1.seq)
      |> Enum.map(& &1.acp_id)
      |> Enum.uniq()
      |> Enum.map(&Envelope.error(&1, -32_603, "Pi process exited: #{inspect(reason)}"))

    queued_messages =
      state.prompt_queue
      |> PromptQueue.to_list()
      |> Enum.map(&Envelope.response(&1.acp_id, %{"stopReason" => "cancelled"}))

    setup_messages =
      for %{type: :setup, plan: plan} <- state.op_queue,
          do: Envelope.error(elem(plan, 1), -32_603, "Pi process exited: #{inspect(reason)}")

    prompt_messages ++ control_messages ++ setup_messages ++ queued_messages
  end

  defp translate_prompt_message(message, images, acp_id, params, state) do
    slash = if images == [], do: SlashCommands.parse(message), else: :error

    cond do
      state.pending_prompt || state.aborted_turn ->
        {messages, state} = PromptFlow.enqueue(acp_id, message, images, params, state)
        {:messages, messages, state}

      match?({:ok, _, _}, slash) ->
        translate_slash_command(slash, acp_id, params, state)

      true ->
        start_requested_prompt(acp_id, message, images, params, state)
    end
  end

  defp start_prompt(acp_id, message, images, params, state) do
    {data, state} = PromptFlow.start_plan(acp_id, message, images, params, state)
    deliver_pending(data, state)
  end

  # A prompt the client sent that Pi never received is not pending: its ACP
  # request is answered with the error.
  defp start_requested_prompt(acp_id, message, images, params, state) do
    case start_prompt(acp_id, message, images, params, state) do
      {:error, reason, state} -> {:error, reason, %{state | pending_prompt: nil, text_acc: []}}
      result -> result
    end
  end

  # session/load and session/resume differ only in whether the transcript is
  # replayed, which also decides whether `get_messages` joins the control group.
  defp plan_session_switch(acp_id, params, replay?, state) do
    session_id = params["sessionId"]
    cwd = params["cwd"] || state.workspace_root || Keyword.get(state.opts, :cwd) || File.cwd!()

    with :ok <- Sessions.require_absolute_cwd(cwd),
         session_file when is_binary(session_file) <- find_session_file(session_id, state) do
      begin_session_setup({:switch, acp_id, session_id, cwd, session_file, replay?}, state)
    else
      {:error, reason} -> {:error, reason, state}
      _ -> {:error, "Unknown sessionId: #{session_id}", state}
    end
  end

  # --- Serialized Pi operations ----------------------------------------------
  #
  # Pi dispatches each input line without awaiting the previous one, and its
  # session changes and set_model finish asynchronously. Two such requests in
  # flight can therefore complete in either order, and nothing tells which one
  # Pi applied last. Every Pi request that reads or changes the session runs as
  # an operation, one at a time:
  #
  #   * a session setup: the change (`new_session`/`switch_session`), then its
  #     queries once Pi has answered the change;
  #   * a switch back to the previous session after a setup that did not
  #     complete (unmanaged only; managed, a new process resumes it);
  #   * a model switch: `set_model`, then its `get_state`/thinking-level refresh;
  #   * the `get_session_stats` usage request after a prompt.
  #
  # The next operation is sent only once the one in flight has its reply or has
  # failed definitively. A queued model switch or usage request reaches Pi only
  # while its session is still the adapter's session, so work for a replaced
  # session is dropped and work for a restored one goes ahead. Prompts, slash
  # commands and notifications such as `set_thinking_level` are not operations.

  @unanswered_change "Pi has not answered an earlier session change"

  @changing_sessions "Pi is changing sessions; send the prompt again once the session change completes"

  # A prompt runs in the session Pi is on, and its updates are tagged with the
  # adapter's session, so a prompt never overlaps a session change. A setup
  # cancels the prompts and prompt commands it finds: they are answered as
  # cancelled and Pi is asked to abort. A prompt that arrives while a setup or
  # a switch back is waiting or running fails at once, because the session it
  # names may not survive the change; the client can send it again once the
  # change has settled which session is current.
  defp begin_session_setup(plan, state) do
    if cancelled_change_unanswered?(state) do
      {:error, @unanswered_change, state}
    else
      {cancelled, abort?, state} = cancel_session_prompts(state)
      {abort, state} = abort_running_prompt(abort?, state)

      result =
        if state.op_in_flight != nil or state.op_queue != [],
          do: deliver_queued(enqueue_op(state, %{type: :setup, plan: plan})),
          else: run_session_setup(plan, state)

      with_setup_notices(result, cancelled, abort, plan)
    end
  end

  defp check_no_session_change(state) do
    changing? =
      match?(%{type: type} when type in [:setup, :switch_back], state.op_in_flight) or
        Enum.any?(state.op_queue, &(&1.type == :setup))

    if changing?, do: {:error, @changing_sessions}, else: :ok
  end

  defp cancel_session_prompts(state) do
    {queued, state} = PromptFlow.cancel_queued(state)

    {running, abort?, state} =
      case state.pending_prompt do
        %{acp_id: acp_id, msg_id: msg_id} ->
          response = Envelope.response(acp_id, %{"stopReason" => "cancelled"})
          state = %{state | pending_prompt: nil, text_acc: [], aborted_turn: %{msg_id: msg_id}}
          {[response], true, state}

        _none ->
          {[], false, state}
      end

    {commands, state} =
      state.control_groups
      |> Map.values()
      |> Enum.reject(&(&1.type in [:session_new, :session_load]))
      |> Enum.sort_by(& &1.seq)
      |> Enum.map_reduce(state, fn group, state ->
        {Envelope.response(group.acp_id, %{"stopReason" => "cancelled"}),
         delete_group(state, group)}
      end)

    # Only a prompt runs a turn that `abort` stops; prompt commands are single
    # requests whose replies are now ignored.
    {running ++ commands ++ queued, abort?, state}
  end

  defp abort_running_prompt(false, state), do: {nil, state}

  defp abort_running_prompt(true, %{managed?: false} = state),
    do: {RPC.encode_notification(RPC.method(:abort)), state}

  defp abort_running_prompt(true, state) do
    _ = write_managed(RPC.encode_notification(RPC.method(:abort)), state)
    {nil, state}
  end

  defp with_setup_notices(result, [], nil, _plan), do: result

  defp with_setup_notices({:ok, :pending, state}, messages, abort, _plan),
    do: add_write({:messages, messages, state}, abort)

  defp with_setup_notices({:ok, data, state}, messages, abort, _plan),
    do: {:messages_and_write, messages, IO.iodata_to_binary([abort || "", data]), state}

  defp with_setup_notices({:error, reason, state}, messages, abort, plan) do
    error = Envelope.error(elem(plan, 1), -32_603, to_string(reason))
    add_write({:messages, messages ++ [error], state}, abort)
  end

  # The client cancelled a setup whose change Pi has not answered (a
  # `session_before_switch` extension may never resolve). Pi will run nothing
  # else that touches the session before it answers, so a new setup fails at
  # once instead of waiting for the client's request timeout.
  defp cancelled_change_unanswered?(state),
    do: match?(%{type: :setup, cancelled?: true}, state.op_in_flight)

  defp reject_waiting_setups(state) do
    {setups, others} = Enum.split_with(state.op_queue, &(&1.type == :setup))

    errors =
      for %{plan: plan} <- setups, do: Envelope.error(elem(plan, 1), -32_603, @unanswered_change)

    {errors, %{state | op_queue: others}}
  end

  defp queued_setup?(%{type: :setup, plan: plan}, acp_id), do: elem(plan, 1) == acp_id
  defp queued_setup?(_op, _acp_id), do: false

  defp running_setup?(%{type: :setup, acp_id: acp_id} = op, acp_id),
    do: not Map.get(op, :cancelled?, false)

  defp running_setup?(_op, _acp_id), do: false

  defp running_setup_group(%{op_in_flight: %{type: :setup, change_id: change_id}} = state),
    do: Enum.find(Map.values(state.control_groups), &(&1[:change_id] == change_id))

  defp running_setup_group(_state), do: nil

  # A setup waiting behind another operation is answered once it has run.
  defp deliver_queued(state), do: {:ok, :pending, state}

  # A model switch replaces a waiting switch for the same session in place, so
  # only the latest one is sent, still ahead of anything requested after it.
  defp enqueue_op(state, %{type: :model_switch, session_id: session_id} = op) do
    index =
      Enum.find_index(
        state.op_queue,
        &match?(%{type: :model_switch, session_id: ^session_id}, &1)
      )

    queue =
      if index, do: List.replace_at(state.op_queue, index, op), else: state.op_queue ++ [op]

    %{state | op_queue: queue}
  end

  # Only the latest usage request for a session matters, too.
  defp enqueue_op(state, %{type: :usage, session_id: session_id} = op) do
    queue = Enum.reject(state.op_queue, &match?(%{type: :usage, session_id: ^session_id}, &1))
    %{state | op_queue: queue ++ [op]}
  end

  defp enqueue_op(state, op), do: %{state | op_queue: state.op_queue ++ [op]}

  # Starts queued operations until one is in flight. Returns what to write (a
  # managed adapter writes to its process directly, so nothing) and the ACP
  # errors of setups that could not start.
  defp advance_ops(state, data \\ [], messages \\ [])

  defp advance_ops(%{op_in_flight: nil, op_queue: [op | rest]} = state, data, messages) do
    case start_op(op, %{state | op_queue: rest}) do
      {:ok, written, state} -> advance_ops(state, [data, written], messages)
      {:messages, new, state} -> advance_ops(state, data, messages ++ new)
      {:error, _reason, state} -> advance_ops(state, data, messages)
    end
  end

  defp advance_ops(state, data, messages) do
    case IO.iodata_to_binary(data) do
      "" -> {nil, messages, state}
      data -> {data, messages, state}
    end
  end

  defp start_op(%{type: :setup, plan: plan}, state) do
    case run_session_setup(plan, state) do
      {:ok, :pending, state} ->
        {:ok, "", state}

      {:ok, data, state} ->
        {:ok, data, state}

      {:error, reason, state} ->
        {:messages, [Envelope.error(elem(plan, 1), -32_603, to_string(reason))], state}
    end
  end

  # Work for a session the adapter no longer serves, or while Pi is on another
  # session than the one the adapter serves, is dropped.
  defp start_op(%{session_id: session_id}, %{session_id: current} = state)
       when session_id != current,
       do: {:messages, [], state}

  defp start_op(_op, %{desynced: %{}} = state), do: {:messages, [], state}

  defp start_op(%{type: :model_switch, fields: fields, session_id: session_id} = queued, state) do
    {id, request, state} = rpc(state, RPC.method(:set_model), fields)

    op = %{
      type: :model_switch,
      phase: :set_model,
      rpc_id: id,
      session_id: session_id,
      acp_id: queued[:acp_id]
    }

    send_op(RPC.line(request), %{state | op_in_flight: op})
  end

  defp start_op(%{type: :usage, session_id: session_id}, state) do
    {id, request, state} = rpc(state, RPC.method(:get_session_stats))
    op = %{type: :usage, rpc_id: id, session_id: session_id}
    send_op(RPC.line(request), %{state | op_in_flight: op})
  end

  defp send_op(data, %{managed?: false} = state), do: {:ok, data, state}

  defp send_op(data, state) do
    case write_managed(data, state) do
      :ok ->
        {:ok, "", state}

      {:error, reason} ->
        Logger.warning("[Pi Adapter] Could not send a Pi request: #{inspect(reason)}")
        {:error, reason, %{state | op_in_flight: nil}}
    end
  end

  defp op_result({:ok, "", state}), do: {:skip, state}
  defp op_result({:ok, data, state}), do: {:skip_and_write, data, state}
  defp op_result({:error, _reason, state}), do: {:skip, state}

  # Adds what advancing the operation queue sends or answers to a result.
  defp advance_after(result) do
    last = tuple_size(result) - 1
    {data, messages, state} = advance_ops(elem(result, last))

    result
    |> put_elem(last, state)
    |> then(&Enum.reduce(messages, &1, fn message, acc -> add_message(acc, message) end))
    |> add_write(data)
  end

  # Adds what advancing the operation queue sends or answers to a reply.
  defp advance_after_reply(result) do
    case split_reply(result) do
      {messages, reply, data, state} ->
        {more_data, more_messages, state} = advance_ops(state)

        data =
          if data && more_data,
            do: IO.iodata_to_binary([data, more_data]),
            else: data || more_data

        with_reply_extras({:reply, reply, state}, messages ++ more_messages, data)

      :error ->
        result
    end
  end

  defp split_reply({:reply, reply, state}), do: {[], reply, nil, state}

  defp split_reply({:messages_and_reply, messages, reply, state}),
    do: {messages, reply, nil, state}

  defp split_reply({:reply_and_write, reply, data, state}), do: {[], reply, data, state}

  defp split_reply({:messages_and_reply_and_write, messages, reply, data, state}),
    do: {messages, reply, data, state}

  defp split_reply(_result), do: :error

  defp add_message({:skip, state}, message), do: {:messages, [message], state}

  defp add_message({:messages, messages, state}, message),
    do: {:messages, messages ++ [message], state}

  defp add_message({:skip_and_write, data, state}, message),
    do: {:messages_and_write, [message], data, state}

  defp add_message({:messages_and_write, messages, data, state}, message),
    do: {:messages_and_write, messages ++ [message], data, state}

  defp add_write(result, nil), do: result
  defp add_write({:skip, state}, data), do: {:skip_and_write, data, state}

  defp add_write({:messages, messages, state}, data),
    do: {:messages_and_write, messages, data, state}

  defp add_write({:skip_and_write, written, state}, data),
    do: {:skip_and_write, IO.iodata_to_binary([written, data]), state}

  defp add_write({:messages_and_write, messages, written, state}, data),
    do: {:messages_and_write, messages, IO.iodata_to_binary([written, data]), state}

  defp op_reply?(%{type: :model_switch, phase: :set_model, rpc_id: id}, id), do: true

  defp op_reply?(%{type: :model_switch, phase: :refresh} = op, id),
    do: id in [op.state_id, op.levels_id]

  defp op_reply?(%{type: :usage, rpc_id: id}, id), do: true
  defp op_reply?(%{type: :switch_back, rpc_id: id}, id), do: true
  defp op_reply?(%{type: :setup, cancelled?: true, change_id: id}, id), do: true
  defp op_reply?(_op, _id), do: false

  # A rejected switch leaves Pi on its previous model, so the refresh runs
  # either way: it also corrects the optimistically reported model. A newer
  # switch for the same session, waiting behind this one, makes it moot.
  defp handle_op_reply(
         event,
         %{op_in_flight: %{type: :model_switch, phase: :set_model} = op} = state
       ) do
    if event["success"] == false do
      Logger.warning("[Pi Adapter] set_model failed: #{inspect(event["error"])}")
    end

    if newer_switch_waiting?(state, op.session_id) or not is_binary(op.session_id) do
      {:skip, %{state | op_in_flight: nil}}
    else
      {state_id, get_state, state} = rpc(state, RPC.method(:get_state))
      {levels_id, get_levels, state} = rpc(state, RPC.method(:get_available_thinking_levels))

      op =
        Map.merge(op, %{
          phase: :refresh,
          state_id: state_id,
          levels_id: levels_id,
          state_data: nil,
          levels_data: nil,
          level_overridden?: false
        })

      op_result(send_op(RPC.encode_many([get_state, get_levels]), %{state | op_in_flight: op}))
    end
  end

  defp handle_op_reply(
         event,
         %{op_in_flight: %{type: :model_switch, phase: :refresh} = op} = state
       ) do
    # A failed member reports no data. Pi 0.80.x has no
    # get_available_thinking_levels, which leaves the static levels.
    data =
      case event do
        %{"success" => false} -> %{}
        %{"data" => data} when is_map(data) -> data
        _ -> %{}
      end

    op =
      if event["id"] == op.state_id,
        do: %{op | state_data: data},
        else: %{op | levels_data: data}

    cond do
      not (is_map(op.state_data) and is_map(op.levels_data)) ->
        {:skip, %{state | op_in_flight: op}}

      newer_switch_waiting?(state, op.session_id) or op.session_id != state.session_id ->
        {:skip, %{state | op_in_flight: nil}}

      true ->
        finish_model_refresh(op, %{state | op_in_flight: nil})
    end
  end

  defp handle_op_reply(event, %{op_in_flight: %{type: :usage} = op} = state) do
    state = %{state | op_in_flight: nil}
    data = if event["success"] == false, do: nil, else: event["data"]

    case op.session_id == state.session_id and context_usage_update(data, op.session_id) do
      %{} = update -> {:messages, [update], state}
      _ -> {:skip, state}
    end
  end

  defp handle_op_reply(event, %{op_in_flight: %{type: :switch_back} = op} = state) do
    state = %{state | op_in_flight: nil}

    if session_change_took_effect?(event) do
      {:skip, state}
    else
      {:skip, desync(state, op.previous.session_id, event["error"] || event["data"])}
    end
  end

  # The client cancelled this setup before Pi answered its change. A success
  # means Pi switched after all, so it is sent back to the previous session.
  defp handle_op_reply(event, %{op_in_flight: %{type: :setup, cancelled?: true} = op} = state) do
    if session_change_took_effect?(event),
      do: start_switch_back(op.previous, state) |> write_or_skip(),
      else: {:skip, %{state | op_in_flight: nil}}
  end

  defp newer_switch_waiting?(state, session_id),
    do: Enum.any?(state.op_queue, &match?(%{type: :model_switch, session_id: ^session_id}, &1))

  defp write_or_skip({nil, state}), do: {:skip, state}
  defp write_or_skip({data, state}), do: {:skip_and_write, data, state}

  # Pi could not return to the session the adapter serves, so the adapter
  # must not claim that session: its prompts and settings fail until a new
  # setup succeeds, and queued work for it is dropped.
  defp desync(state, session_id, reason) do
    Logger.warning("[Pi Adapter] Pi did not return to session #{session_id}: #{inspect(reason)}")

    %{
      state
      | desynced: %{session_id: session_id},
        op_queue: Enum.filter(state.op_queue, &(&1.type == :setup))
    }
  end

  defp check_synced(%{desynced: %{session_id: session_id}}) do
    {:error,
     "Pi is not on session #{session_id}: it could not switch back after a session change " <>
       "that did not complete. Load or create a session to continue."}
  end

  defp check_synced(_state), do: :ok

  defp run_session_setup({:new, acp_id, cwd}, state) do
    previous = previous_session(state)

    case prepare_session_process(cwd, nil, state) do
      {:ok, state} -> start_session_new(acp_id, cwd, previous, state)
      {:error, reason, failed_state} -> {:error, reason, failed_state}
    end
  end

  defp run_session_setup({:switch, acp_id, session_id, cwd, session_file, replay?}, state) do
    previous = previous_session(state)

    case prepare_session_process(cwd, session_file, state) do
      {:ok, state} ->
        start_session_switch(acp_id, session_id, cwd, session_file, replay?, previous, state)

      {:error, reason, failed_state} ->
        {:error, reason, failed_state}
    end
  end

  @restored_session_fields [:cwd, :workspace_root, :settings, :last_session_cwd, :startup_sent?]

  # What a failed setup restores: a setup prepares its session before Pi
  # answers, and a managed one also replaces the Pi process. Model work for
  # the previous session waits in the operation queue behind the setup.
  defp previous_session(state) do
    %{
      session_id: state.session_id,
      session_file: state.session_file,
      fields: Map.take(state, @restored_session_fields)
    }
  end

  # The ACP request of a failed or cancelled setup fails, so the client keeps
  # using its previous session, and the adapter keeps serving it:
  #   * Unmanaged, Pi stays on that session unless the change had already
  #     succeeded; then Pi is switched back to the previous session's file.
  #     The adapter's workspace and settings, which the setup pointed at the
  #     requested cwd, go back either way.
  #   * Managed, the setup already replaced the Pi process (a load starts it
  #     with `--session <requested file>`), so a new process resumes the
  #     previous session's file. With no previous session the replacement
  #     process is closed.
  # Either way the setup operation ends (or becomes the switch back), and the
  # previous session's queued model work goes ahead.
  defp restore_previous_session(%{previous: previous} = group, %{managed?: false} = state) do
    state = Map.merge(state, previous.fields)

    if session_change_succeeded?(group),
      do: start_switch_back(previous, state),
      else: {nil, %{state | op_in_flight: nil}}
  end

  defp restore_previous_session(%{previous: %{session_file: file} = previous}, state)
       when is_binary(file) do
    cwd = previous.fields.workspace_root || previous.fields.cwd

    case prepare_session_process(cwd, file, state) do
      {:ok, state} ->
        {nil, Map.merge(state, previous.fields)}

      {:error, reason, state} ->
        Logger.warning("[Pi Adapter] Could not restore the previous session: #{reason}")
        {nil, Map.merge(state, previous.fields)}
    end
  end

  defp restore_previous_session(%{previous: previous}, state),
    do: {nil, state |> close_active_session() |> Map.merge(previous.fields)}

  defp restore_previous_session(_group, state), do: {nil, state}

  defp session_change_succeeded?(group),
    do: Map.has_key?(group.responses, :new_session) or Map.has_key?(group.responses, :switch)

  # Unmanaged, Pi itself has to switch back: the switch back is the operation
  # in flight until Pi answers it.
  defp start_switch_back(%{session_file: file} = previous, state) when is_binary(file) do
    {id, request, state} = rpc(state, RPC.method(:switch_session), %{"sessionPath" => file})
    op = %{type: :switch_back, rpc_id: id, previous: previous}
    {RPC.line(request), %{state | op_in_flight: op}}
  end

  defp start_switch_back(previous, state) do
    state = %{state | op_in_flight: nil}

    if previous.session_id,
      do: {nil, desync(state, previous.session_id, :no_session_file)},
      else: {nil, state}
  end

  # The ACP request of the running setup ended: the client timed it out,
  # cancelled it, or went away (the ACP client sends `$/cancel_request` in
  # each case). The request fails at once and the client keeps its previous
  # session, but no outcome is assumed that Pi has not reported:
  #   * Unmanaged, with the change unanswered, the setup stays in flight as a
  #     cancelled change until Pi answers it (see handle_op_reply/2); setups
  #     that arrive meanwhile fail at once.
  #   * Managed, replacing the Pi process ends the change; the previous
  #     session's process is restored.
  #   * Once the change succeeded, Pi is returned to the previous session; the
  #     setup's queries are untracked and their replies are ignored.
  defp cancel_session_setup(op, state) do
    error = Envelope.error(op.acp_id, -32_800, "Request cancelled")
    group = running_setup_group(state)
    change_pending? = Map.has_key?(state.pending_controls, op.change_id)
    state = if group, do: delete_group(state, group), else: state

    {data, messages, state} =
      if change_pending? and not state.managed? do
        state =
          Map.merge(%{state | op_in_flight: Map.put(op, :cancelled?, true)}, op.previous.fields)

        {errors, state} = reject_waiting_setups(state)
        {nil, errors, state}
      else
        {data, state} =
          restore_previous_session(group || %{previous: op.previous, responses: %{}}, state)

        {data, [], tag_switch_back(state, op.acp_id)}
      end

    advance_after(add_write({:messages, [error | messages], state}, data))
  end

  defp tag_switch_back(%{op_in_flight: %{type: :switch_back} = op} = state, acp_id),
    do: %{state | op_in_flight: Map.put(op, :cancelled_request, acp_id)}

  defp tag_switch_back(state, _acp_id), do: state

  defp start_session_switch(acp_id, session_id, cwd, session_file, replay?, previous, state) do
    file_commands = SlashCommands.load(cwd, state.opts)
    settings = Settings.load(cwd, state.opts)

    followups =
      if(replay?, do: [{:messages, RPC.method(:get_messages), %{}}], else: []) ++
        session_setup_followups()

    group = %{
      type: :session_load,
      acp_id: acp_id,
      previous: previous,
      session_id: session_id,
      cwd: cwd,
      session_file: session_file,
      file_commands: file_commands,
      settings: settings,
      replay?: replay?,
      responses: %{}
    }

    start_session_change(
      group,
      {:switch, RPC.method(:switch_session), %{"sessionPath" => session_file}},
      followups,
      state
    )
  end

  defp start_session_new(acp_id, cwd, previous, state) do
    file_commands = SlashCommands.load(cwd, state.opts)
    settings = Settings.load(cwd, state.opts)

    group = %{
      type: :session_new,
      acp_id: acp_id,
      previous: previous,
      cwd: cwd,
      file_commands: file_commands,
      settings: settings,
      responses: %{}
    }

    start_session_change(
      group,
      {:new_session, RPC.method(:new_session), %{}},
      session_setup_followups(),
      state
    )
  end

  defp session_setup_followups do
    [
      {:state, RPC.method(:get_state), %{}},
      {:models, RPC.method(:get_available_models), %{}},
      {:thinking_levels, RPC.method(:get_available_thinking_levels), %{}},
      {:commands, RPC.method(:get_commands), %{}}
    ]
  end

  # Pi dispatches each input line without awaiting the previous one, and its
  # new_session/switch_session replace the session only after several
  # asynchronous steps. Requests written alongside them would describe the
  # session Pi is leaving, so a setup group sends the session change alone and
  # the rest of its requests once Pi has answered it.
  defp start_session_change(group, {kind, type, fields}, followups, state) do
    {change_id, change, state} = rpc(state, type, fields)

    group =
      Map.merge(group, %{
        change_id: change_id,
        refs: MapSet.new([change_id]),
        followups: followups
      })

    op = %{type: :setup, acp_id: group.acp_id, change_id: change_id, previous: group.previous}

    state =
      state
      |> put_group(group)
      |> put_control(change_id, kind, group)
      |> Map.put(:op_in_flight, op)

    deliver_pending(RPC.line(change), state)
  end

  # Built in emission order, so the ids ascend the way they are sent.
  defp send_session_setup_followups(group, state) do
    {requests, state} =
      Enum.map_reduce(group.followups, state, fn {kind, type, fields}, acc ->
        {id, message, acc} = rpc(acc, type, fields)
        {{kind, id, message}, acc}
      end)

    group = %{
      group
      | followups: [],
        refs: MapSet.union(group.refs, MapSet.new(requests, fn {_kind, id, _msg} -> id end))
    }

    state = %{state | control_groups: Map.put(state.control_groups, group.group_id, group)}

    state =
      Enum.reduce(requests, state, fn {kind, id, _msg}, acc ->
        put_control(acc, id, kind, group)
      end)

    {:skip_and_write, RPC.encode_many(Enum.map(requests, fn {_kind, _id, msg} -> msg end)), state}
  end

  defp translate_slash_command({:ok, name, args}, acp_id, params, state) do
    context = %{
      acp_id: acp_id,
      params: params,
      session_id: params["sessionId"] || state.session_id
    }

    route_slash_command(name, args, context, state)
  end

  defp route_slash_command(name, args, context, state)
       when name in ["compact", "autocompact", "export", "session", "name", "changelog"] do
    case name do
      "compact" -> slash_compact(args, context, state)
      "autocompact" -> slash_autocompact(args, context, state)
      "export" -> slash_export(context, state)
      "session" -> slash_session(context, state)
      "name" -> slash_name(args, context, state)
      "changelog" -> slash_changelog(context, state)
    end
  end

  defp route_slash_command(name, args, context, state)
       when name in ["steering", "follow-up", "model", "thinking"] do
    case name do
      "steering" -> slash_steering(args, context, state)
      "follow-up" -> slash_follow_up(args, context, state)
      "model" -> slash_model_notice(context, state)
      "thinking" -> slash_thinking_notice(context, state)
    end
  end

  defp route_slash_command(name, args, context, state) do
    slash_file_or_prompt(name, args, context, state)
  end

  defp slash_compact(args, context, state) do
    custom = args |> Enum.join(" ") |> blank_to_nil()

    start_control_command(
      :slash_compact,
      context.acp_id,
      context.session_id,
      "compact",
      %{"customInstructions" => custom},
      state
    )
  end

  defp slash_autocompact([mode | _], context, state)
       when mode in ["on", "true", "enable", "enabled"] do
    start_control_command(
      :slash_autocompact_on,
      context.acp_id,
      context.session_id,
      "set_auto_compaction",
      %{"enabled" => true},
      state
    )
  end

  defp slash_autocompact([mode | _], context, state)
       when mode in ["off", "false", "disable", "disabled"] do
    start_control_command(
      :slash_autocompact_off,
      context.acp_id,
      context.session_id,
      "set_auto_compaction",
      %{"enabled" => false},
      state
    )
  end

  defp slash_autocompact(_args, context, state) do
    start_control_command(
      :slash_autocompact_toggle_get,
      context.acp_id,
      context.session_id,
      "get_state",
      %{},
      state
    )
  end

  defp slash_export(context, state) do
    safe_id = (context.session_id || "default") |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
    output_path = Path.join(state.cwd || File.cwd!(), "pi-session-#{safe_id}.html")

    start_control_command(
      :slash_export,
      context.acp_id,
      context.session_id,
      "export_html",
      %{"outputPath" => output_path},
      state
    )
  end

  defp slash_session(context, state) do
    start_control_command(
      :slash_session,
      context.acp_id,
      context.session_id,
      "get_session_stats",
      %{},
      state
    )
  end

  defp slash_changelog(context, state) do
    case Startup.changelog(state.opts) do
      {:ok, text} -> prompt_message(context.acp_id, context.session_id, text, state)
      {:error, reason} -> prompt_message(context.acp_id, context.session_id, reason, state)
    end
  end

  defp slash_name([], context, state) do
    prompt_message(context.acp_id, context.session_id, "Usage: /name <name>", state)
  end

  defp slash_name(name_parts, context, state) do
    name_value = Enum.join(name_parts, " ")

    start_control_command(
      :slash_name,
      context.acp_id,
      context.session_id,
      "set_session_name",
      %{"name" => name_value},
      state,
      %{name: name_value}
    )
  end

  defp slash_steering([], context, state) do
    start_control_command(
      :slash_steering_get,
      context.acp_id,
      context.session_id,
      "get_state",
      %{},
      state
    )
  end

  defp slash_steering([mode | _], context, state) when mode in ["all", "one-at-a-time"] do
    start_control_command(
      :slash_steering_set,
      context.acp_id,
      context.session_id,
      "set_steering_mode",
      %{"mode" => mode},
      state,
      %{mode: mode}
    )
  end

  defp slash_steering(_args, context, state) do
    prompt_message(
      context.acp_id,
      context.session_id,
      "Usage: /steering all | /steering one-at-a-time",
      state
    )
  end

  defp slash_follow_up([], context, state) do
    start_control_command(
      :slash_follow_up_get,
      context.acp_id,
      context.session_id,
      "get_state",
      %{},
      state
    )
  end

  defp slash_follow_up([mode | _], context, state) when mode in ["all", "one-at-a-time"] do
    start_control_command(
      :slash_follow_up_set,
      context.acp_id,
      context.session_id,
      "set_follow_up_mode",
      %{"mode" => mode},
      state,
      %{mode: mode}
    )
  end

  defp slash_follow_up(_args, context, state) do
    prompt_message(
      context.acp_id,
      context.session_id,
      "Usage: /follow-up all | /follow-up one-at-a-time",
      state
    )
  end

  defp slash_model_notice(context, state) do
    prompt_message(
      context.acp_id,
      context.session_id,
      "Use the ACP model selector to change models.",
      state
    )
  end

  defp slash_thinking_notice(context, state) do
    prompt_message(
      context.acp_id,
      context.session_id,
      "Use the ACP mode selector to change thinking level.",
      state
    )
  end

  defp slash_file_or_prompt(name, args, context, state) do
    case SlashCommands.expand_file_command(name, args, state.file_commands) do
      nil ->
        message = "/" <> name <> slash_args(args)
        start_requested_prompt(context.acp_id, message, [], context.params, state)

      expanded ->
        start_requested_prompt(context.acp_id, expanded, [], context.params, state)
    end
  end

  defp start_control_command(type, acp_id, session_id, command, params, state, extra \\ %{}) do
    {rpc_id, rpc_msg, state} = rpc(state, command, RPC.compact(params))

    group =
      %{
        type: type,
        acp_id: acp_id,
        session_id: session_id,
        refs: MapSet.new([rpc_id]),
        responses: %{}
      }
      |> Map.merge(extra)

    state =
      state
      |> put_group(group)
      |> put_control(rpc_id, :result, group)

    # A command Pi never received is not pending: its ACP request is answered
    # with the error.
    case deliver_pending(RPC.line(rpc_msg), state) do
      {:error, reason, state} -> {:error, reason, delete_group(state, group_for(state, rpc_id))}
      result -> result
    end
  end

  defp group_for(state, rpc_id),
    do: Enum.find(Map.values(state.control_groups), &MapSet.member?(&1.refs, rpc_id))

  defp prompt_message(_acp_id, session_id, text, state) do
    message = AdapterEvents.agent_message_chunk(session_id, text)

    {:messages_and_reply, [message], %{"stopReason" => "end_turn"}, state}
  end

  defp context_usage_update(%{"contextUsage" => usage}, session_id) when is_map(usage) do
    used = usage["tokens"]
    size = usage["contextWindow"]

    if is_integer(used) and used >= 0 and used <= 9_007_199_254_740_991 and
         is_integer(size) and size > 0 and size <= 9_007_199_254_740_991 do
      AdapterEvents.session_update_type(session_id, "usage_update", %{
        "used" => used,
        "size" => size
      })
    end
  end

  defp context_usage_update(_data, _session_id), do: nil

  defp session_title_update(title, state) do
    notification =
      AdapterEvents.session_info_update(state.session_id, %{
        "title" => title,
        "updatedAt" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })

    {:messages, [notification], state}
  end

  # Pi dispatches each input line without awaiting the previous one, and its
  # set_model assigns the model only after an asynchronous auth check, so a
  # model switch is a serialized operation: set_model, then the refresh, sent
  # only once Pi has answered set_model. The ACP request is answered at once
  # with the optimistic configuration.
  defp translate_set_model(model_id, session_id_override, acp_id, state) do
    with :ok <- check_synced(state),
         {:ok, messages, fields, state} <-
           Config.set_model_plan(model_id, session_id_override, state) do
      op = %{type: :model_switch, fields: fields, session_id: state.session_id, acp_id: acp_id}

      if state.op_in_flight == nil and state.op_queue == [] do
        case start_op(op, state) do
          {:ok, data, state} -> deliver_messages_and_config_result(messages, data, state)
          {:messages, _dropped, state} -> deliver_messages_and_config_result(messages, "", state)
          {:error, reason, state} -> {:error, inspect(reason), state}
        end
      else
        deliver_messages_and_config_result(messages, "", enqueue_op(state, op))
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # A model switch for the current session, in flight or waiting, ends with a
  # refresh that publishes the level against the new model's levels.
  defp refresh_will_publish?(state) do
    session_id = state.session_id

    match?(%{type: :model_switch, session_id: ^session_id}, state.op_in_flight) or
      newer_switch_waiting?(state, session_id)
  end

  defp session_change_took_effect?(%{"success" => false}), do: false
  defp session_change_took_effect?(event), do: not cancelled_session_change?(event)

  defp cancelled_session_change?(%{"data" => %{"cancelled" => true}}), do: true
  defp cancelled_session_change?(_event), do: false

  defp finish_model_refresh(refresh, state) do
    levels = Config.available_levels(refresh.levels_data["levels"])

    # A set_mode, or a thinking_level_changed event, after the refresh was sent
    # is newer than the level its get_state reported.
    reported =
      if refresh.level_overridden?,
        do: state.thinking_level,
        else: refresh.state_data["thinkingLevel"] || state.thinking_level

    state = %{
      state
      | available_thinking_levels: levels,
        thinking_level: Config.normalize_thinking_level(reported, levels),
        current_model_id: reported_model_id(refresh.state_data) || state.current_model_id
    }

    {:messages,
     [
       AdapterEvents.current_mode_update(refresh.session_id, state.thinking_level),
       Config.config_options_update(refresh.session_id, state)
     ], state}
  end

  defp reported_model_id(%{"model" => %{"provider" => provider, "id" => id}})
       when is_binary(provider) and provider != "" and is_binary(id) and id != "",
       do: "#{provider}/#{id}"

  defp reported_model_id(_state_data), do: nil

  defp override_refresh_level(
         %{op_in_flight: %{type: :model_switch, phase: :refresh} = op} = state
       ),
       do: %{state | op_in_flight: %{op | level_overridden?: true}}

  defp override_refresh_level(state), do: state

  defp process_response(event, id, state) do
    cond do
      PromptFlow.response_error?(id, event, state) ->
        finish_prompt_error(event, state)

      # Pi refused the cancelled prompt, so it runs no turn to wait for.
      event["success"] == false and match?(%{msg_id: ^id}, state.aborted_turn) ->
        finish_aborted_turn(state)

      true ->
        case Map.pop(state.pending_controls, id) do
          {nil, pending_controls} ->
            process_untracked_response(event, %{state | pending_controls: pending_controls})

          {control, pending_controls} ->
            state = %{state | pending_controls: pending_controls}
            handle_control_response(control, event, state)
        end
    end
  end

  defp process_event(%{"type" => "response", "id" => id} = event, state) when is_binary(id) do
    result =
      if op_reply?(state.op_in_flight, id),
        do: handle_op_reply(event, state),
        else: process_response(event, id, state)

    advance_after(result)
  end

  # The aborted turn's prompt is answered, so what it still streams has no
  # prompt to belong to.
  defp process_event(%{"type" => type}, %{pending_prompt: nil, aborted_turn: %{}} = state)
       when type in [
              "message_update",
              "tool_execution_start",
              "tool_execution_update",
              "tool_execution_end"
            ],
       do: {:skip, state}

  defp process_event(
         %{
           "type" => "message_update",
           "assistantMessageEvent" => %{"type" => "text_delta", "delta" => delta}
         },
         state
       ) do
    state = %{state | text_acc: [delta | state.text_acc]}

    notification = AdapterEvents.agent_message_chunk(state.session_id, delta)

    {:messages, [notification], state}
  end

  defp process_event(
         %{
           "type" => "message_update",
           "assistantMessageEvent" => %{"type" => "thinking_delta", "delta" => delta}
         },
         state
       ) do
    notification = AdapterEvents.agent_thought_chunk(state.session_id, delta)

    {:messages, [notification], state}
  end

  defp process_event(
         %{
           "type" => "message_update",
           "assistantMessageEvent" => %{"type" => type} = tool_event
         },
         state
       )
       when type in ["toolcall_start", "toolcall_delta", "toolcall_end", "tool_call"] do
    {notification, state} = Events.tool_call_stream_update(tool_event, state)

    if notification do
      {:messages, [notification], state}
    else
      {:skip, state}
    end
  end

  defp process_event(
         %{
           "type" => "tool_execution_start",
           "toolCallId" => tool_call_id,
           "toolName" => tool_name
         } = event,
         state
       ) do
    args = event["args"] || %{}
    {line, state} = maybe_snapshot_edit(tool_call_id, tool_name, args, state)

    {notification, state} =
      Events.tool_execution_start(tool_call_id, tool_name, args, line, state)

    {:messages, [notification], state}
  end

  defp process_event(
         %{
           "type" => "tool_execution_update",
           "toolCallId" => tool_call_id
         } = event,
         state
       ) do
    notification =
      Events.tool_execution_update(state.session_id, tool_call_id, event["partialResult"])

    {:messages, [notification], state}
  end

  defp process_event(
         %{
           "type" => "tool_execution_end",
           "toolCallId" => tool_call_id
         } = event,
         state
       ) do
    result = event["result"]
    is_error = event["isError"] == true
    text = Tools.result_text(result)
    {content, state} = tool_result_content(tool_call_id, text, is_error, state)

    {notification, state} =
      Events.tool_execution_end(tool_call_id, result, is_error, content, state)

    {:messages, [notification], state}
  end

  defp process_event(%{"type" => "agent_end"} = event, state) do
    state = %{state | last_usage: Events.usage_from_agent_end(event)}

    if state.pending_prompt do
      state = enqueue_op(state, %{type: :usage, session_id: state.session_id})
      advance_after({:skip, state})
    else
      {:skip, state}
    end
  end

  # Pi serializes a cleared session name as a missing `name` key, so a missing
  # (or null) name clears the ACP title.
  defp process_event(%{"type" => "session_info_changed"} = event, state) do
    case Map.get(event, "name") do
      name when is_binary(name) ->
        session_title_update(String.trim(name), state)

      nil ->
        session_title_update(nil, state)

      _invalid ->
        Logger.debug("[Pi Adapter] Ignoring session_info_changed with a non-string name")
        {:skip, state}
    end
  end

  # Pi reports every effective thinking-level change, including the level a
  # model switch selects and the clamp it applies to an unsupported
  # set_thinking_level.
  # While a setup or a switch back runs, Pi may be on either session; the
  # setup's own get_state reports the level.
  defp process_event(
         %{"type" => "thinking_level_changed"},
         %{op_in_flight: %{type: type}} = state
       )
       when type in [:setup, :switch_back],
       do: {:skip, state}

  defp process_event(%{"type" => "thinking_level_changed", "level" => level}, state)
       when is_binary(level) and level != "" do
    previous = state.thinking_level
    state = override_refresh_level(%{state | thinking_level: level})

    cond do
      # The refresh that follows a model switch publishes the level against
      # the new model's levels.
      refresh_will_publish?(state) ->
        {:skip, state}

      level == previous or not is_binary(state.session_id) ->
        {:skip, state}

      true ->
        levels = Config.available_levels(state.available_thinking_levels)

        {:messages,
         [
           AdapterEvents.current_mode_update(
             state.session_id,
             Config.normalize_thinking_level(level, levels)
           ),
           Config.config_options_update(state.session_id, state)
         ], state}
    end
  end

  defp process_event(
         %{"type" => "agent_settled"},
         %{pending_prompt: nil, aborted_turn: %{}} = state
       ),
       do: finish_aborted_turn(state)

  defp process_event(%{"type" => "agent_settled"}, %{pending_prompt: nil} = state) do
    {:skip, %{state | last_usage: %{}}}
  end

  defp process_event(%{"type" => "agent_settled"}, state) do
    {response, state} = PromptFlow.settle(state)
    start_queued_after([response], state)
  end

  defp process_event(%{"type" => type} = event, state)
       when type in [
              "auto_compaction_start",
              "auto_compaction_end",
              "auto_retry_start",
              "auto_retry_end"
            ] do
    {:messages, Events.auto_status_messages(state.session_id, type, event), state}
  end

  defp process_event(%{"type" => "extension_ui_request"} = event, state) do
    handle_extension_ui_request(event, state)
  end

  defp process_event(%{"type" => type}, state)
       when type in [
              "agent_start",
              "turn_start",
              "turn_end",
              "message_start",
              "message_end",
              "message_update"
            ] do
    {:skip, state}
  end

  defp process_event(event, state) do
    Logger.debug("[Pi Adapter] Unhandled event: #{inspect(event["type"])}")
    {:skip, state}
  end

  defp handle_extension_ui_request(%{"id" => id, "method" => "select"} = event, state)
       when is_binary(id) and id != "" do
    options = Enum.map(List.wrap(event["options"]), &to_string/1)

    if options == [] do
      cancel_extension_ui(id, [], state)
    else
      permission_options =
        options
        |> Enum.with_index()
        |> Enum.map(fn {name, index} ->
          %{"optionId" => "choice-#{index}", "name" => name, "kind" => "allow_once"}
        end)

      request_extension_ui_permission(id, :select, event, options, permission_options, state)
    end
  end

  defp handle_extension_ui_request(%{"id" => id, "method" => "confirm"} = event, state)
       when is_binary(id) and id != "" do
    permission_options = [
      %{"optionId" => "yes", "name" => "Yes", "kind" => "allow_once"},
      %{"optionId" => "no", "name" => "No", "kind" => "reject_once"}
    ]

    request_extension_ui_permission(id, :confirm, event, [], permission_options, state)
  end

  defp handle_extension_ui_request(%{"id" => id, "method" => method}, state)
       when is_binary(id) and method in ["input", "editor"] do
    message =
      AdapterEvents.agent_message_chunk(
        state.session_id,
        "Pi #{method} UI request is not supported in ACP yet; cancelling it."
      )

    cancel_extension_ui(id, [message], state)
  end

  defp handle_extension_ui_request(%{"id" => id, "method" => "notify"} = event, state)
       when is_binary(id) do
    message =
      AdapterEvents.agent_message_chunk(state.session_id, event["message"] || "Pi notification")
      |> put_in(["params", "update", "_meta"], %{
        "piAcp" => %{"notify" => %{"level" => event["notifyType"] || "info"}}
      })

    cancel_extension_ui(id, [message], state)
  end

  defp handle_extension_ui_request(%{"id" => id}, state) when is_binary(id) do
    cancel_extension_ui(id, [], state)
  end

  defp handle_extension_ui_request(_event, state), do: {:skip, state}

  defp request_extension_ui_permission(
         pi_id,
         kind,
         event,
         options,
         permission_options,
         state
       ) do
    counter = state.msg_counter + 1
    acp_id = "pi-extension-#{counter}"

    tool_call = %{
      "toolCallId" => "pi-ui-#{pi_id}",
      "title" => event["title"] || event["message"] || "Pi extension request",
      "kind" => "other",
      "status" => "pending",
      "rawInput" => extension_ui_raw_input(event)
    }

    request =
      Envelope.request(
        "session/request_permission",
        %{
          "sessionId" => state.session_id,
          "toolCall" => tool_call,
          "options" => permission_options,
          "_meta" => %{"piAcp" => %{"extensionUi" => %{"method" => event["method"]}}}
        },
        acp_id
      )

    pending =
      Map.put(state.pending_extension_ui, acp_id, %{
        pi_id: pi_id,
        kind: kind,
        options: options
      })

    {:messages, [request], %{state | pending_extension_ui: pending, msg_counter: counter}}
  end

  defp extension_ui_raw_input(event) do
    Enum.reduce(
      ["title", "message", "options", "placeholder", "prefill"],
      %{"method" => event["method"]},
      fn key, raw_input ->
        if Map.has_key?(event, key), do: Map.put(raw_input, key, event[key]), else: raw_input
      end
    )
  end

  # Inbound, so a managed adapter's own write of the cancel, and its failure,
  # go through the managed follow-up path.
  defp cancel_extension_ui(pi_id, messages, state) do
    {:messages_and_write, messages, RPC.line(cancelled_extension_ui_response(pi_id)), state}
  end

  defp resolve_extension_ui_response(acp_id, result, state) do
    case Map.pop(state.pending_extension_ui, acp_id) do
      {nil, _pending} ->
        {:ok, :skip, state}

      {request, pending} ->
        response = extension_ui_response(request, result)
        answered = %{acp_id: acp_id, pi_id: request.pi_id}
        state = %{state | pending_extension_ui: pending, answered_ui: answered}
        deliver_ui_answer(RPC.line(response), request.pi_id, state)
    end
  end

  defp deliver_ui_answer(data, _pi_id, %{managed?: false} = state), do: {:ok, data, state}

  # Pi waits for the dialog's answer with no timeout, so when it cannot be
  # written a cancel takes its place. When that fails too, Pi's input is
  # broken: Pi is closed, and its exit is handled, answering what it had
  # pending, once the bridge sees it go. Either way the client hears of the
  # write error.
  defp deliver_ui_answer(data, pi_id, state) do
    with {:error, reason} <- write_managed(data, state) do
      case write_managed(RPC.line(cancelled_extension_ui_response(pi_id)), state) do
        :ok -> :ok
        {:error, _reason} -> PortRunner.close(state.port)
      end

      {:error, inspect(reason), state}
    else
      :ok -> {:ok, :pending, state}
    end
  end

  defp extension_ui_response(request, result) do
    option_id = get_in(result, ["outcome", "optionId"])
    selected? = get_in(result, ["outcome", "outcome"]) == "selected"

    case {request.kind, selected?, option_id} do
      {:confirm, true, "yes"} ->
        RPC.request(request.pi_id, RPC.method(:extension_ui_response), %{"confirmed" => true})

      {:confirm, true, "no"} ->
        RPC.request(request.pi_id, RPC.method(:extension_ui_response), %{"confirmed" => false})

      {:select, true, "choice-" <> index} ->
        with {index, ""} <- Integer.parse(index),
             value when is_binary(value) <- Enum.at(request.options, index) do
          RPC.request(request.pi_id, RPC.method(:extension_ui_response), %{"value" => value})
        else
          _invalid -> cancelled_extension_ui_response(request.pi_id)
        end

      _cancelled ->
        cancelled_extension_ui_response(request.pi_id)
    end
  end

  defp cancelled_extension_ui_response(pi_id) do
    RPC.request(pi_id, RPC.method(:extension_ui_response), %{"cancelled" => true})
  end

  defp handle_control_response(%{group_id: group_id, kind: kind, rpc_id: rpc_id}, event, state) do
    group = Map.fetch!(state.control_groups, group_id)
    event = tolerate_optional_control_failure(kind, event)

    cond do
      event["success"] == false and auth_error?(event["error"]) ->
        finish_control_error(group, auth_required_error(group.acp_id, state), state)

      event["success"] == false ->
        finish_control_error(
          group,
          Envelope.error(group.acp_id, -32_603, to_string(event["error"])),
          state
        )

      # An extension can cancel the change; Pi then stays on its session.
      kind in [:new_session, :switch] and cancelled_session_change?(event) ->
        finish_control_error(
          group,
          Envelope.error(group.acp_id, -32_603, "Pi cancelled the session change"),
          state
        )

      true ->
        group =
          group
          |> update_in([:responses], &Map.put(&1, kind, event["data"] || %{}))
          |> update_in([:refs], &MapSet.delete(&1, rpc_id))

        state = %{state | control_groups: Map.put(state.control_groups, group_id, group)}

        if Map.get(group, :followups, []) != [] and kind in [:new_session, :switch],
          do: send_session_setup_followups(group, state),
          else: maybe_finish_control_group(group, state)
    end
  end

  # Pi added `get_available_thinking_levels` in 0.81.0, and older Pi rejects it
  # as an unknown command. The reply only narrows the advertised levels, so a
  # failed reply means "no model-specific levels": the session falls back to
  # the static levels instead of failing setup.
  defp tolerate_optional_control_failure(:thinking_levels, %{"success" => false} = event) do
    Logger.debug(
      "[Pi Adapter] get_available_thinking_levels failed; using the static levels: " <>
        inspect(event["error"])
    )

    %{event | "success" => true} |> Map.put("data", %{})
  end

  defp tolerate_optional_control_failure(_kind, event), do: event

  defp maybe_finish_control_group(%{refs: refs} = group, state) do
    if MapSet.size(refs) == 0 do
      finish_control_group(group, state)
    else
      {:skip, state}
    end
  end

  defp finish_control_group(%{type: :session_new} = group, state) do
    state = delete_group(state, group)
    state_data = group.responses[:state] || %{}
    models_data = group.responses[:models] || %{}
    session_file = state_data["sessionFile"]

    if Sessions.empty_models?(models_data) do
      state = maybe_cleanup_failed_session(session_file, state)
      error = auth_required_error(group.acp_id, state)
      group |> restore_previous_session(state) |> with_messages([error])
    else
      session_id = state_data["sessionId"] || "pi-#{System.unique_integer([:positive])}"
      finish_established_session(group, state, state_data, models_data, session_id)
    end
  end

  defp finish_control_group(%{type: :session_load} = group, state) do
    state = delete_group(state, group)
    state_data = group.responses[:state] || %{}
    models_data = group.responses[:models] || %{}

    if Sessions.empty_models?(models_data) do
      state = maybe_cleanup_failed_session(group.session_file, state)
      error = auth_required_error(group.acp_id, state)
      group |> restore_previous_session(state) |> with_messages([error])
    else
      finish_established_session(group, state, state_data, models_data, group.session_id)
    end
  end

  defp finish_control_group(%{type: :slash_autocompact_toggle_get} = group, state) do
    data = group.responses[:result] || %{}
    enabled = not truthy?(data["autoCompactionEnabled"])

    {rpc_id, rpc_msg, state} =
      rpc(state, RPC.method(:set_auto_compaction), %{"enabled" => enabled})

    group =
      group
      |> Map.put(:type, :slash_autocompact_toggle_set)
      |> Map.put(:enabled, enabled)
      |> Map.put(:refs, MapSet.new([rpc_id]))
      |> Map.put(:responses, %{})

    state =
      state
      |> put_group(group)
      |> put_control(rpc_id, :result, group)

    {:skip_and_write, RPC.line(rpc_msg), state}
  end

  defp finish_control_group(group, state) do
    state = delete_group(state, group)

    messages = group |> slash_result_messages(state) |> maybe_add_name_update(group, state)

    response = Envelope.response(group.acp_id, %{"stopReason" => "end_turn"})
    {:messages, messages ++ [response], state}
  end

  # session/new and a settled session switch produce the same state transition
  # and the same response; only the session id and the optional replay differ.
  defp finish_established_session(group, state, state_data, models_data, session_id) do
    # The setup operation is done. A model switch queued behind it for the
    # session it replaced is dropped when it reaches the head of the queue.
    state = %{state | op_in_flight: nil, desynced: nil}
    cwd = state_data["cwd"] || group.cwd
    session_file = state_data["sessionFile"] || group[:session_file]
    models = Config.model_state(models_data, state_data)
    modes = Config.thinking_state(state_data, group.responses[:thinking_levels] || %{})
    settings = group[:settings] || state.settings || %{}
    commands = command_state(group.responses[:commands], group.file_commands, settings)

    maybe_store_session(state.session_map_path, session_id, cwd, session_file)

    state =
      Sessions.establish(state, %{
        session_id: session_id,
        session_file: session_file,
        cwd: cwd,
        models: models,
        modes: modes,
        commands: commands,
        file_commands: group.file_commands,
        settings: settings
      })

    # The cwd the agent reports is bookkeeping only. Edit-snapshot containment
    # keeps the host-authorized session cwd so a misbehaving agent cannot
    # widen its own workspace root.
    state = %{state | workspace_root: group.cwd || state.workspace_root}

    replay = replay_messages_for(group, session_id)
    response = Sessions.session_response(group.acp_id, session_id, session_file, models, modes)
    {startup_messages, state} = startup_messages(session_id, cwd, state, settings)

    messages =
      replay ++
        [response] ++ startup_messages ++ [available_commands_update(session_id, commands)]

    {:messages, messages, state}
  end

  defp replay_messages_for(%{type: :session_load, replay?: false}, _session_id), do: []

  defp replay_messages_for(%{type: :session_load} = group, session_id),
    do: Events.replay_messages(group.responses[:messages], session_id)

  defp replay_messages_for(_group, _session_id), do: []

  defp finish_control_error(group, error, state) do
    state = delete_group(state, group)
    group |> restore_previous_session(state) |> with_messages([error])
  end

  defp with_messages({nil, state}, messages), do: {:messages, messages, state}
  defp with_messages({data, state}, messages), do: {:messages_and_write, messages, data, state}

  defp finish_prompt_error(event, state) do
    acp_id = state.pending_prompt.acp_id

    error =
      if auth_error?(event["error"]) do
        auth_required_error(acp_id, state)
      else
        Envelope.error(acp_id, -32_603, to_string(event["error"] || "Pi prompt failed"))
      end

    # Pi runs no turn for a prompt it refused, so the next queued prompt
    # starts now instead of waiting for an agent_settled that never comes.
    start_queued_after([error], %{state | pending_prompt: nil, text_acc: []})
  end

  defp finish_aborted_turn(state),
    do: start_queued_after([], %{state | aborted_turn: nil, last_usage: %{}})

  # Answers `messages` and starts the next queued prompt, if any.
  defp start_queued_after(messages, state) do
    case start_next_queued_prompt(state) do
      {:ok, started, nil, state} ->
        inbound_messages(messages ++ started, state)

      {:ok, started, write_data, state} ->
        {:messages_and_write, messages ++ started, write_data, state}

      {:error, reason, state} ->
        {:messages, failures, state} = fail_managed_input(state, {:write_failed, reason})
        inbound_messages(messages ++ failures, state)

      :empty ->
        inbound_messages(messages, state)
    end
  end

  # An untracked reply answers nothing the adapter is waiting for. It never
  # changes the session state: a late setup reply would describe whichever
  # session Pi had when it read the request, not necessarily the current one.
  defp process_untracked_response(_event, state), do: {:skip, state}

  # Edit snapshots are only taken for files inside the session workspace and
  # below a size cap: the old/new contents are sent to the ACP client as a
  # diff, so an agent-named path must not be able to exfiltrate arbitrary
  # files (absolute paths, `..`, or symlink escapes) or force huge reads.
  @max_edit_snapshot_bytes 1_048_576

  defp maybe_snapshot_edit(tool_call_id, "edit", %{"path" => path} = args, state)
       when is_binary(path) do
    with {:ok, abs} <- snapshot_path(path, state),
         {:ok, old_text} <- read_snapshot_file(abs) do
      line = Tools.find_unique_line_number(old_text, args["oldText"] || "")
      snapshot = %{path: path, abs: abs, old_text: old_text}
      {line, %{state | edit_snapshots: Map.put(state.edit_snapshots, tool_call_id, snapshot)}}
    else
      _ -> {nil, state}
    end
  end

  defp maybe_snapshot_edit(_tool_call_id, _tool_name, _args, state), do: {nil, state}

  defp snapshot_path(_path, %{workspace_root: nil}), do: :error

  defp snapshot_path(path, %{workspace_root: root}) do
    lexical = if Path.type(path) == :absolute, do: path, else: Path.expand(path, root)
    abs = WorkspacePath.canonical(lexical)

    if Path.type(root) == :absolute and WorkspacePath.within?(abs, root),
      do: {:ok, abs},
      else: :error
  end

  defp read_snapshot_file(abs) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(abs),
         true <- size <= @max_edit_snapshot_bytes,
         {:ok, text} <- File.read(abs),
         true <- byte_size(text) <= @max_edit_snapshot_bytes do
      {:ok, text}
    else
      _ -> :error
    end
  end

  defp tool_result_content(tool_call_id, text, is_error, state) do
    snapshot = state.edit_snapshots[tool_call_id]
    state = %{state | edit_snapshots: Map.delete(state.edit_snapshots, tool_call_id)}

    content =
      with false <- is_error,
           %{} <- snapshot,
           {:ok, abs} <- snapshot_path(snapshot.abs, state),
           {:ok, new_text} when new_text != snapshot.old_text <- read_snapshot_file(abs) do
        [
          %{
            "type" => "diff",
            "path" => snapshot.path,
            "oldText" => snapshot.old_text,
            "newText" => new_text
          }
        ] ++ (Tools.text_content(text) || [])
      else
        _ -> Tools.text_content(text)
      end

    {content, state}
  end

  defp start_next_queued_prompt(state) do
    case PromptFlow.next_queued(state) do
      {:ok, queued, state} ->
        case start_prompt(queued.acp_id, queued.message, queued.images, queued.params, state) do
          {:ok, data, state} ->
            write_data = if data == :pending, do: nil, else: data
            {:ok, PromptFlow.queue_started_messages(state), write_data, state}

          {:error, reason, state} ->
            {:error, reason, state}
        end

      :empty ->
        :empty
    end
  end

  defp slash_result_messages(%{type: :slash_export, session_id: session_id} = group, _state) do
    text = slash_result_text(group)
    path = get_in(group.responses, [:result, "path"])

    text_message = AdapterEvents.agent_message_chunk(session_id, text)

    link_message =
      if is_binary(path) and path != "" do
        AdapterEvents.resource_link_chunk(session_id, "file://#{path}", name: Path.basename(path))
      end

    [text_message, link_message] |> Enum.reject(&is_nil/1)
  end

  defp slash_result_messages(group, state) do
    [
      AdapterEvents.agent_message_chunk(
        group.session_id || state.session_id,
        slash_result_text(group)
      )
    ]
  end

  defp slash_result_text(%{type: :slash_compact, responses: %{result: result}}) do
    summary = if is_map(result), do: result["summary"], else: nil
    tokens = if is_map(result), do: result["tokensBefore"], else: nil

    [
      "Compaction completed.",
      if(is_number(tokens), do: "Tokens before: #{tokens}", else: nil),
      summary
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp slash_result_text(%{type: :slash_autocompact_on}), do: "Auto-compaction enabled."
  defp slash_result_text(%{type: :slash_autocompact_off}), do: "Auto-compaction disabled."

  defp slash_result_text(%{type: :slash_autocompact_toggle_set, enabled: enabled}),
    do: "Auto-compaction #{if(enabled, do: "enabled", else: "disabled")}."

  defp slash_result_text(%{type: :slash_export, responses: %{result: result}}) do
    path = if is_map(result), do: result["path"], else: nil

    if is_binary(path) and path != "",
      do: "Session exported: file://#{path}",
      else: "Session export completed."
  end

  defp slash_result_text(%{type: :slash_session, responses: %{result: stats}})
       when is_map(stats) do
    [
      maybe_line("Session", stats["sessionId"]),
      maybe_line("Session file", stats["sessionFile"]),
      maybe_line("Messages", stats["totalMessages"]),
      maybe_line("Cost", stats["cost"])
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "Session stats:\n#{Jason.encode!(stats, pretty: true)}"
      lines -> Enum.join(lines, "\n")
    end
  end

  defp slash_result_text(%{type: :slash_name, name: name}), do: "Session name set: #{name}"
  defp slash_result_text(%{type: :slash_name}), do: "Session name set."

  defp slash_result_text(%{type: :slash_steering_get, responses: %{result: state}}),
    do: "Steering mode: #{state["steeringMode"] || "unknown"}"

  defp slash_result_text(%{type: :slash_steering_set, mode: mode}),
    do: "Steering mode set to: #{mode}"

  defp slash_result_text(%{type: :slash_steering_set}), do: "Steering mode updated."

  defp slash_result_text(%{type: :slash_follow_up_get, responses: %{result: state}}),
    do: "Follow-up mode: #{state["followUpMode"] || "unknown"}"

  defp slash_result_text(%{type: :slash_follow_up_set, mode: mode}),
    do: "Follow-up mode set to: #{mode}"

  defp slash_result_text(%{type: :slash_follow_up_set}), do: "Follow-up mode updated."
  defp slash_result_text(_group), do: "Command completed."

  defp maybe_add_name_update(
         messages,
         %{type: :slash_name, session_id: session_id, responses: %{result: result}} = group,
         _state
       ) do
    title = group[:name] || if(is_map(result), do: result["name"], else: nil)

    if is_binary(title) and title != "" do
      [
        AdapterEvents.session_info_update(session_id, %{
          "title" => title,
          "updatedAt" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        })
        | messages
      ]
    else
      messages
    end
  end

  defp maybe_add_name_update(messages, _group, _state), do: messages

  defp command_state(data, file_commands, settings) do
    pi_commands =
      data
      |> pi_commands()
      |> Enum.reject(&(&1["source"] == "extension"))
      |> maybe_filter_skill_commands(settings)
      |> Enum.map(fn command ->
        %{
          "name" => command["name"],
          "description" => command["description"] || "(command)",
          "input" => command["input"]
        }
        |> SlashCommands.normalize_input()
        |> RPC.compact()
      end)

    (pi_commands ++ SlashCommands.available_commands(file_commands))
    |> Enum.reduce({MapSet.new(), []}, fn command, {seen, acc} ->
      name = command["name"]

      if is_binary(name) and name != "" and not MapSet.member?(seen, name) do
        {MapSet.put(seen, name), [command | acc]}
      else
        {seen, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp pi_commands(%{"commands" => commands}) when is_list(commands), do: commands
  defp pi_commands(%{"data" => %{"commands" => commands}}) when is_list(commands), do: commands
  defp pi_commands(_data), do: []

  defp maybe_filter_skill_commands(commands, settings) do
    if Settings.enable_skill_commands?(settings) do
      commands
    else
      Enum.reject(commands, &(&1["source"] == "skill"))
    end
  end

  defp startup_messages(_session_id, _cwd, %{startup_sent?: true} = state, _settings),
    do: {[], state}

  defp startup_messages(_session_id, _cwd, %{managed?: false} = state, _settings),
    do: {[], %{state | startup_sent?: true}}

  defp startup_messages(session_id, cwd, state, settings) do
    case Startup.build(cwd, settings, state.prelude_lines) do
      nil ->
        {[], %{state | startup_sent?: true}}

      text ->
        message = AdapterEvents.agent_message_chunk(session_id, text)

        {[message], %{state | startup_sent?: true}}
    end
  end

  defp available_commands_update(session_id, commands) do
    AdapterEvents.available_commands_update(session_id, commands)
  end

  defp find_session_file(session_id, state) when is_binary(session_id) do
    case SessionStore.get(state.session_map_path, session_id) do
      %{"sessionFile" => session_file} when is_binary(session_file) ->
        session_file

      _ ->
        SessionStore.find_pi_session_file(session_id,
          session_dir: state.session_dir,
          agent_dir: Keyword.get(state.opts, :agent_dir)
        )
    end
  end

  defp find_session_file(_session_id, _state), do: nil

  defp maybe_store_session(_map_path, _session_id, _cwd, nil), do: :ok

  defp maybe_store_session(map_path, session_id, cwd, session_file) do
    SessionStore.upsert(map_path, %{
      "sessionId" => session_id,
      "cwd" => cwd,
      "sessionFile" => session_file
    })
  end

  defp maybe_cleanup_failed_session(nil, state), do: close_active_session(state)

  defp maybe_cleanup_failed_session(session_file, state) do
    state = close_active_session(state)

    if state.delete_session_files? do
      safe_delete_session_file(state, session_file)
    end

    state
  end

  defp maybe_delete_session_file(%{delete_session_files?: false}, _entry), do: :ok

  defp maybe_delete_session_file(state, %{"sessionFile" => session_file})
       when is_binary(session_file),
       do: safe_delete_session_file(state, session_file)

  defp maybe_delete_session_file(_state, _entry), do: :ok

  defp safe_delete_session_file(state, session_file) do
    root =
      state.session_dir ||
        Path.join(Settings.agent_dir(state.opts), "sessions")

    # Resolve symlinks before comparing so a sessions-root link that points
    # outside cannot pass a lexical prefix check and delete the target.
    WorkspacePath.rm_within(session_file, root)
  end

  # `seq` records creation order. Never order groups by `group_id`: map order
  # is lexicographic on the id string, so "group-1000" sorts before
  # "group-999".
  defp put_group(state, group) do
    seq = System.unique_integer([:positive, :monotonic])

    group =
      group
      |> Map.put_new(:seq, seq)
      |> Map.put_new(:group_id, "group-#{seq}")

    %{state | control_groups: Map.put(state.control_groups, group.group_id, group)}
  end

  defp put_control(state, rpc_id, kind, group) do
    group_id = group[:group_id] || latest_group_id(state, group)

    control =
      rpc_id
      |> RPC.control_entry(kind, group_id)
      |> Map.put(:inserted_at, System.monotonic_time(:millisecond))

    %{state | pending_controls: Map.put(state.pending_controls, rpc_id, control)}
  end

  defp latest_group_id(state, group) do
    state.control_groups
    |> Map.values()
    |> Enum.filter(&(&1.acp_id == group.acp_id and &1.type == group.type))
    |> Enum.max_by(& &1.seq, fn -> %{group_id: nil} end)
    |> Map.fetch!(:group_id)
  end

  defp delete_group(state, group) do
    refs = group.refs || MapSet.new()

    pending_controls =
      Enum.reduce(refs, state.pending_controls, fn rpc_id, pending ->
        Map.delete(pending, rpc_id)
      end)

    %{
      state
      | pending_controls: pending_controls,
        control_groups: Map.delete(state.control_groups, group.group_id)
    }
  end

  # Correlation ids are minted from a counter on the adapter state, the way
  # prompt ids already are. A VM-global sequence made the emitted ids depend on
  # unrelated activity in the same VM, and made the order they were bound in
  # invisible to the golden fixtures, which normalize ids by first appearance.
  defp rpc(state, type, fields \\ %{}) do
    {id, counter} = RPC.next_rpc_id(state.rpc_counter)
    {id, RPC.request(id, type, fields), %{state | rpc_counter: counter}}
  end

  defp open_session_process(cmd, args, opts, state) do
    case PortRunner.open(cmd, args, opts, __MODULE__) do
      {:ok, port} ->
        [actor] = Subprocess.linked_processes(port)

        {:ok,
         %{
           state
           | port: port,
             port_monitor: Process.monitor(actor),
             framing: nil,
             subprocess_error: nil,
             cleanup_result: :ok
         }}

      {:error, reason} ->
        {:error, inspect(reason), state}
    end
  end

  defp rpc_args(opts) do
    args = ["--mode", "rpc", "--no-themes"]

    if RuntimeHome.trust_workspace_config?(opts) do
      args
    else
      args ++ ["--no-context-files", "--no-approve"]
    end
  end

  defp session_dir(opts) do
    case Keyword.get(opts, :session_dir) do
      dir when is_binary(dir) and dir != "" ->
        Path.expand(dir)

      _ ->
        case RuntimeHome.env_value(opts, "PI_CODING_AGENT_SESSION_DIR") do
          dir when is_binary(dir) and dir != "" -> Path.expand(dir)
          _ -> nil
        end
    end
  end

  defp maybe_put_session_dir(env, opts) do
    case session_dir(opts) do
      nil -> env
      dir -> Map.put(env, "PI_CODING_AGENT_SESSION_DIR", dir)
    end
  end

  defp reject_workspace_cli(cli_path, opts) do
    cwd = Keyword.get(opts, :cwd)
    explicit? = explicit_cli_path?(opts)

    if explicit? or not is_binary(cwd) or cwd == "" do
      {:ok, cli_path}
    else
      case resolved_cli(cli_path) do
        resolved when is_binary(resolved) ->
          if WorkspacePath.within?(resolved, cwd) do
            {:error, {:invalid_option, :cli_path, "refusing a workspace Pi executable"}}
          else
            {:ok, cli_path}
          end

        _missing ->
          {:ok, cli_path}
      end
    end
  end

  defp explicit_cli_path?(opts) do
    Keyword.has_key?(opts, :cli_path) or Keyword.has_key?(opts, :pi_command)
  end

  defp resolved_cli(cmd) when is_binary(cmd) do
    if Path.type(cmd) == :absolute, do: Path.expand(cmd), else: System.find_executable(cmd)
  end

  defp resolved_cli(_cmd), do: nil

  defp terminal_home_env(opts) do
    case RuntimeHome.path(opts, :pi) do
      nil -> %{}
      path -> %{"PI_CODING_AGENT_DIR" => path}
    end
  end

  defp append_opt(args, opts, key, flag) do
    case Keyword.get(opts, key) do
      nil ->
        {:ok, args}

      value ->
        string = to_string(value)

        if String.starts_with?(string, "-") do
          {:error, {:invalid_option, key, "must not start with '-'"}}
        else
          {:ok, args ++ [flag, string]}
        end
    end
  end

  defp maybe_keyword_put(keyword, _key, nil), do: keyword
  defp maybe_keyword_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp translate_config_option(config_id, value, acp_id, state) do
    if config_id == Config.model_config_id() do
      translate_set_model(value, nil, acp_id, state)
    else
      case Config.update_plan(config_id, value, state) do
        {:ack, data} ->
          deliver_ack(data, state)

        {:ok, messages, data, state} ->
          deliver_messages_and_config_result(messages, data, override_refresh_level(state))

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  defp auth_required_error(id, state) do
    Envelope.error(
      id,
      Types.auth_required_code(),
      "Configure an API key or log in with an OAuth provider.",
      %{"authMethods" => auth_methods(state.opts)}
    )
  end

  defp auth_error?(message) do
    text = message |> to_string() |> String.downcase()

    Enum.any?(
      [
        "api key",
        "apikey",
        "missing key",
        "no key",
        "not configured",
        "unauthorized",
        "authentication",
        "permission denied",
        "forbidden",
        "401",
        "403"
      ],
      &String.contains?(text, &1)
    )
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp slash_args([]), do: ""
  defp slash_args(args), do: " " <> Enum.join(args, " ")

  defp maybe_line(_label, nil), do: nil
  defp maybe_line(label, value), do: "#{label}: #{value}"
end
