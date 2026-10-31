defmodule Arbor.ACP.Adapters.ClaudeSDK do
  @moduledoc """
  Adapter for Claude Code using the Claude Agent SDK process protocol.

  This adapter launches Claude Code with the same stream-json flags used by
  `@anthropic-ai/claude-agent-sdk`, including the SDK entrypoint environment and
  stdio permission prompt control channel.

  Each ACP session owns a Claude Code process, so sessions on one connection
  do not share SDK conversation state. `command/1` therefore returns
  `:adapter_managed` by default. Session-store calls that take a `cwd`
  (`session/new`, `session/load`, `session/resume`, `session/list`,
  `session/fork`, `session/delete`) reject a working directory outside
  `:workspace_roots` (default the adapter `:cwd`); paths are canonicalized
  with `Arbor.ACP.AdapterSupport.WorkspacePath`.

  ## MCP servers

  Claude Code takes MCP servers only when it starts, so they are adapter
  options, not session parameters:

    * `:mcp_servers` - a map of server name to Claude's own server config, for
      example `%{"docs" => %{"type" => "http", "url" => url, "headers" => %{}}}`
      or `%{"fs" => %{"command" => "fs-mcp", "args" => [], "env" => %{}}}`.
      The adapter writes it to a file readable only by the current user (0600,
      in a fresh 0700 directory under `System.tmp_dir/0`) and passes the path,
      so headers and environment values never appear in the process arguments,
      which other local users can read. The file is removed when the process
      that launched Claude Code (the adapter bridge) exits. Anything other than
      a map, such as an ACP-style `mcpServers` list, makes `command/1` return
      `{:error, {:invalid_option, :mcp_servers, message}}`.
    * `:mcp_config_path` - a path, or a list of paths, to Claude MCP config
      JSON files (`{"mcpServers": {...}}`) that you manage yourself. A relative
      path is resolved against `:cwd`. A path that is not an existing file is
      an `{:invalid_option, :mcp_config_path, message}` error.
    * `:strict_mcp_config` - when true, Claude Code uses only the servers given
      through the options above and ignores user and project MCP configuration
      (including a workspace `.mcp.json`). Defaults to true unless the host
      sets `:trust_workspace_config`.
    * `:setting_sources` - Claude Code `--setting-sources` value (default
      `"user"`). Project and local sources are omitted so a workspace
      `.claude/settings*.json` cannot install hooks. Pass an explicit list or
      `:trust_workspace_config` to restore the previous sources.
    * `:trust_workspace_config` - opt back into loading workspace Claude
      settings, `.mcp.json`, and the host Claude config directory.
    * `:claude_config_dir` - Claude config directory. When omitted, the
      adapter mints a private 0700 directory per ACP session, stores it on
      adapter and session-store state, and sets `CLAUDE_CONFIG_DIR` for the
      child and for terminal login. Existing `~/.claude` logins and settings
      are invisible unless this option or `:trust_workspace_config` is set.

  The `mcpServers` of `session/new`, `session/load`, `session/resume` and
  `session/fork` are not attached: the Claude Code process is already running.
  `capabilities/0` therefore advertises no MCP transport and sets
  `mcpCapabilities._meta.ex_mcp.claude_sdk.sessionMcpServers` to `false`, and
  the adapter logs a warning when a request names a server the launch options
  did not configure. (Servers in a `:mcp_config_path` file are not known to the
  adapter, so a launch that has one is not checked.)
  """

  @behaviour Arbor.ACP.Adapter

  @impl true
  def name, do: "claude_sdk"

  require Logger

  alias Arbor.ACP.Adapters.ClaudeSDK.Mapper
  alias Arbor.ACP.Adapters.ClaudeSDK.MCPConfig
  alias Arbor.ACP.Adapters.ClaudeSDK.Protocol, as: ClaudeProtocol
  alias Arbor.ACP.Adapters.ClaudeSDK.SessionStore
  alias Arbor.ACP.AdapterSupport.Subprocess, as: PortRunner
  alias Arbor.ACP.AdapterSupport.WorkspacePath
  alias Arbor.RPC.JSONRPC, as: Envelope
  alias Arbor.RPC.Subprocess
  alias Arbor.ACP.Adapters.Internal.PromptQueue
  alias Arbor.ACP.Adapters.Internal.RuntimeHome

  @session_fields [
    :session_id,
    :claude_session_id,
    :model,
    :permission_mode,
    :effort,
    :cwd,
    :fast_mode_enabled,
    :current_agent,
    :pending_prompt_id,
    :active_prompt_session_id,
    :init_response,
    :bypass_allowed?,
    :auto_fallback_warned?,
    :auto_fallback_pending?,
    :last_model_usage,
    :turn_model_usage,
    :pending_controls,
    :pending_client_requests,
    :prompt_queue,
    :available_commands,
    :available_models,
    :available_agents,
    :text_acc,
    :thinking_acc,
    :thinking_blocks,
    :current_block_type,
    :current_assistant_text_streamed?,
    :stream_message_id,
    :tool_calls,
    :message_ids,
    :background_subagents,
    :deferred_result,
    :last_write
  ]

  # `session/fork` fork point, as claude-agent-acp reads it: an explicitly
  # versioned object under `_meta.jetbrains.air.fork`.
  @fork_meta_path ["_meta", "jetbrains", "air", "fork"]
  @fork_meta_version 1
  @session_scoped_methods ~w(
    session/prompt
    session/set_mode
    session/set_config_option
    session/cancel
  )

  defstruct [
    :session_id,
    # Claude Code's own session UUID (from the stream-json `init` event). Kept
    # apart from the ACP-facing `session_id` — see Mapper.maybe_set_session/2.
    :claude_session_id,
    :model,
    :permission_mode,
    :effort,
    :cwd,
    # Snapshot of the adapter `:cwd` at init; implicit workspace-root checks
    # use this (or `:workspace_roots`) rather than the current session cwd.
    :workspace_root,
    :client_capabilities,
    :gateway_auth,
    :fast_mode_enabled,
    :current_agent,
    :pending_prompt_id,
    :active_prompt_session_id,
    :init_response,
    # False when the host opted this session out of bypassPermissions through
    # `_meta.claudeCode.options.allowDangerouslySkipPermissions: false`.
    bypass_allowed?: true,
    # Auto-mode fallback bookkeeping: the notice is published at most once per
    # session, and a fallback decided while `session/new` is still in flight is
    # held until the first prompt (the client cannot receive a session update
    # for a session id it has not been given yet).
    auto_fallback_warned?: false,
    auto_fallback_pending?: false,
    # `result.modelUsage` is a running total for the whole Claude process, so
    # `last_model_usage` is the previous reading and `turn_model_usage` the
    # increments accumulated for the turn being answered.
    last_model_usage: %{},
    turn_model_usage: %{},
    opts: [],
    pending_controls: %{},
    pending_client_requests: %{},
    prompt_queue: PromptQueue.new(),
    available_commands: [],
    available_models: [],
    available_agents: [],
    text_acc: [],
    thinking_acc: [],
    thinking_blocks: [],
    current_block_type: nil,
    current_assistant_text_streamed?: false,
    # Anthropic API message id of the assistant message currently streaming,
    # captured from the `message_start` stream event so the deltas that follow
    # (which never carry it) can be stamped with the same, transcript-stable
    # id. Cleared wherever a turn ends or a session is dropped.
    stream_message_id: nil,
    tool_calls: %{},
    message_ids: %{},
    background_subagents: MapSet.new(),
    deferred_result: nil,
    # What the latest outbound translation started or answered before its
    # write (the prompt, control request ids, the Auto fallback notice it
    # consumed, and the Claude request a client response answered), so a write
    # the bridge could not make can be retired; see outbound_write_failed/3.
    last_write: %{prompt: nil, controls: [], notice: nil, answered: nil},
    # When true (the default), each ACP session owns a Claude process so
    # sessions on one connection do not share SDK state. Unit and golden
    # tests set `managed: false` and keep the single-process translation path.
    managed?: true,
    cleanup_result: :ok,
    home_cleanup_errors: %{},
    port: nil,
    session_processes: %{},
    session_aliases: [],
    # Per-session launch overrides (e.g. a minted CLAUDE_CONFIG_DIR). Merged
    # into the child command so each process can have its own home.
    session_homes: %{}
  ]

  @impl true
  def environment_defaults(_opts), do: Arbor.ACP.Adapters.Internal.Environment.defaults()

  @impl true
  def init(opts) do
    opts = RuntimeHome.put_opt(opts, :claude)

    {:ok,
     %__MODULE__{
       opts: opts,
       cwd: Keyword.get(opts, :cwd),
       workspace_root: Keyword.get(opts, :cwd),
       session_id: Keyword.get(opts, :session_id) || Keyword.get(opts, :resume),
       claude_session_id: Keyword.get(opts, :session_id) || Keyword.get(opts, :resume),
       model: Keyword.get(opts, :model),
       permission_mode: encode_permission_mode(Keyword.get(opts, :permission_mode, :default)),
       effort: Keyword.get(opts, :effort),
       fast_mode_enabled: Keyword.get(opts, :fast_mode, false),
       current_agent: Keyword.get(opts, :agent, "default"),
       managed?: Keyword.get(opts, :managed, true)
     }}
  end

  @impl true
  def command(opts) do
    if Keyword.get(opts, :managed, true) do
      with :ok <- MCPConfig.validate(opts) do
        :adapter_managed
      end
    else
      cli_command(opts)
    end
  end

  defp cli_command(opts) do
    opts = Keyword.delete(opts, :managed)

    with {:ok, opts} <- MCPConfig.prepare(opts) do
      ClaudeProtocol.command(opts)
    end
  end

  @impl true
  def env(opts), do: ClaudeProtocol.env(opts)

  @impl true
  def post_connect(state) do
    request_id = control_id("initialize")

    state = %{
      state
      | pending_controls: Map.put(state.pending_controls, request_id, :initialize)
    }

    {:ok, ClaudeProtocol.initialize_request(state.opts, request_id) |> ClaudeProtocol.line(),
     state}
  end

  @impl true
  def capabilities do
    %{
      "loadSession" => true,
      "promptCapabilities" => %{
        "image" => true,
        "embeddedContext" => true
      },
      # Session `mcpServers` are never attached (see "MCP servers" in the
      # moduledoc); servers are launch options.
      "mcpCapabilities" => %{
        "acp" => false,
        "http" => false,
        "sse" => false,
        "_meta" => %{"ex_mcp" => %{"claude_sdk" => %{"sessionMcpServers" => false}}}
      },
      "auth" => %{
        "logout" => %{}
      },
      "sessionCapabilities" => %{
        "list" => %{},
        "resume" => %{},
        "close" => %{},
        "delete" => %{},
        "fork" => %{},
        "additionalDirectories" => %{}
      },
      "_meta" => %{
        "ex_mcp" => %{
          "claude_sdk" => %{
            "streaming" => true,
            "controlProtocol" => true
          }
        }
      }
    }
  end

  @impl true
  def auth_methods(opts), do: auth_methods(opts, %__MODULE__{})

  @impl true
  def auth_methods(opts, state) do
    opts = Keyword.merge(Map.get(state, :opts, []), opts)

    []
    |> maybe_add_terminal_auth_methods(opts, state)
    |> maybe_add_gateway_auth_methods(opts, state)
  end

  @impl true
  def modes, do: Mapper.modes()

  @impl true
  def config_options do
    Mapper.config_options(%{
      available_models: [],
      model: "default",
      permission_mode: "default",
      effort: "medium"
    })
  end

  @impl true
  def list_sessions(params, state) do
    with {:ok, cwd} <- session_cwd(params, state),
         :ok <- authorize_workspace(cwd, :session_list, state) do
      params
      |> session_store_opts(state)
      |> Map.put(:cwd, cwd)
      |> SessionStore.list_acp_sessions_from_homes(session_store_homes(state))
      |> case do
        {:ok, sessions} -> {:ok, sessions, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def fork_session(params, state) do
    warn_unattached_mcp_servers("session/fork", params, state)
    session_id = params["sessionId"] || state.session_id

    with {:ok, cwd} <- session_cwd(params, state),
         :ok <- authorize_workspace(cwd, :session_fork, state) do
      params
      |> session_store_opts(state)
      |> Map.put(:cwd, cwd)
      |> put_fork_message_id(params)
      |> then(&SessionStore.fork_session(native_session_id(state, session_id), &1))
      |> case do
        {:ok, forked_session_id} ->
          previous = persist_current_session(state)
          state = previous
          parent_fields = parent_session_fields(session_id, state)
          state = reset_session_fields(state)

          state = %{
            state
            | session_id: forked_session_id,
              claude_session_id: forked_session_id,
              cwd: cwd,
              bypass_allowed?: Map.get(parent_fields, :bypass_allowed?, true),
              permission_mode: Map.get(parent_fields, :permission_mode),
              model: Map.get(parent_fields, :model),
              effort: Map.get(parent_fields, :effort),
              fast_mode_enabled: Map.get(parent_fields, :fast_mode_enabled),
              current_agent: Map.get(parent_fields, :current_agent)
          }

          state = ensure_session_home(state, forked_session_id)

          parent_opts =
            params
            |> Map.put("sessionId", session_id)
            |> session_store_opts(state)
            |> Map.put(:cwd, cwd)

          result =
            with :ok <-
                   relocate_fork(
                     forked_session_id,
                     cwd,
                     parent_opts,
                     session_home_opts(state, forked_session_id)
                   ) do
              start_session_process(forked_session_id, cwd, params, :fork, state)
            else
              {:error, reason} -> {:error, reason, state}
            end

          case result do
            {:ok, state} ->
              {:ok, Mapper.session_result(state, forked_session_id), state}

            {:error, reason, failed} ->
              failed = close_session_process(failed, forked_session_id)
              failed = release_session_home(failed, forked_session_id)

              if failed.cleanup_result == :ok do
                _ = SessionStore.delete_session(forked_session_id, parent_opts)
                {:error, reason, previous}
              else
                retained =
                  Map.take(failed, [
                    :session_processes,
                    :session_homes,
                    :home_cleanup_errors,
                    :cleanup_result
                  ])

                {:error, reason, Map.merge(previous, retained)}
              end
          end

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def translate_outbound(_msg, %{cleanup_result: {:error, reason}} = state),
    do: {:error, "Claude child cleanup is unconfirmed: #{inspect(reason)}", state}

  def translate_outbound(msg, state) do
    state = maybe_switch_session(msg, state)
    msg |> route_outbound(state) |> remember_write(state) |> deliver_managed(msg)
  end

  @impl true
  def subprocess_receipt(message, state) do
    Enum.find_value(state.session_processes, fn {_session_id, entry} ->
      case PortRunner.event(entry.handle, message) do
        {:frame, token, _bytes} -> {entry.handle, token}
        _other -> nil
      end
    end)
  end

  @impl true
  def handle_adapter_message({:arbor_rpc, _generation, _event} = message, state) do
    case find_session_event(message, state) do
      {session_id, handle, {:frame, _token, line}} ->
        state = switch_session(state, session_id)
        inbound_to_adapter_message(translate_inbound(line, state), handle)

      {session_id, handle, {:closed, _reason, remainder}} ->
        state = switch_session(state, session_id)

        {messages, state} =
          remainder
          |> String.split("\n", trim: true)
          |> Enum.reduce({[], state}, fn line, {acc, acc_state} ->
            case inbound_to_adapter_message(translate_inbound(line, acc_state), handle) do
              {:messages, extra, acc_state} -> {acc ++ extra, acc_state}
              {:skip, acc_state} -> {acc, acc_state}
            end
          end)

        {cancelled, state} = cleanup_session(state, session_id)
        adapter_messages(messages ++ cancelled, state)

      _other ->
        {:skip, state}
    end
  end

  def handle_adapter_message({:DOWN, monitor, :process, _pid, _reason}, state)
      when is_reference(monitor) do
    case find_session_by_monitor(state, monitor) do
      {session_id, _handle} ->
        state = switch_session(state, session_id)
        {messages, state} = cleanup_session(state, session_id)
        adapter_messages(messages, state)

      nil ->
        {:skip, state}
    end
  end

  def handle_adapter_message(_message, state), do: {:skip, state}

  defp adapter_messages([], state), do: {:skip, persist_current_session(state)}

  defp adapter_messages(messages, state),
    do: {:messages, messages, persist_current_session(state)}

  @impl true
  def shutdown(%{managed?: false} = state), do: {:ok, state}

  def shutdown(state) do
    state = refresh_cleanup_result(state)

    state =
      Enum.reduce(state.session_processes, state, fn {id, entry}, acc ->
        forget_session_process(acc, id, entry.handle)
      end)

    state = Enum.reduce(Map.keys(state.session_homes), state, &release_session_home(&2, &1))

    case state.cleanup_result do
      :ok ->
        case RuntimeHome.release(state.opts, :claude) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason, %{state | cleanup_result: {:error, reason}}}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # The bridge writes what translate_outbound/2 returns. When it cannot, it
  # answers the request with the error and calls this, so nothing the write
  # was to start is tracked any more: Claude never received it.
  #
  # Only what that translation recorded is retired. Matching the failed
  # message's id instead would confuse directions: the client's response to a
  # request Claude made can carry the same id as a prompt already running.
  @impl true
  def outbound_write_failed(_message, reason, state) do
    %{prompt: prompt, controls: controls, notice: notice, answered: answered} = state.last_write

    state = %{
      state
      | pending_controls: Map.drop(state.pending_controls, controls),
        last_write: %{prompt: nil, controls: [], notice: nil, answered: nil}
    }

    # The notice went out with the write's notifications, which were dropped.
    state = if notice, do: Map.merge(state, notice), else: state
    state = retire_unsent_prompt(prompt, state)

    # Claude is still waiting on the request the client answered; a small
    # error takes the place of the answer that could not be written.
    case answered do
      %{request_id: request_id} ->
        error = "The ACP client's response could not be forwarded: #{inspect(reason)}"

        {:write, request_id |> ClaudeProtocol.control_error(error) |> ClaudeProtocol.line(),
         state}

      nil ->
        state
    end
  end

  defp retire_unsent_prompt(id, %{pending_prompt_id: id} = state) when id != nil do
    %{
      state
      | pending_prompt_id: nil,
        active_prompt_session_id: nil,
        text_acc: [],
        thinking_acc: [],
        thinking_blocks: [],
        current_block_type: nil,
        current_assistant_text_streamed?: false,
        stream_message_id: nil,
        tool_calls: %{},
        background_subagents: MapSet.new(),
        deferred_result: nil
    }
  end

  defp retire_unsent_prompt(_prompt, state), do: state

  # Only a translation that writes can fail to; the others leave the record
  # of the last write alone.
  defp writes?({:ok, data, _state}), do: data not in [:skip, :pending]
  defp writes?({:pending_and_write, _data, _state}), do: true
  defp writes?({:reply_and_write, _result, _data, _state}), do: true
  defp writes?({:messages_and_write, _messages, _data, _state}), do: true
  defp writes?({:messages_and_reply_and_write, _messages, _result, _data, _state}), do: true
  defp writes?(_result), do: false

  defp remember_write(result, before) do
    last = tuple_size(result) - 1

    case {writes?(result), elem(result, last)} do
      {true, %__MODULE__{} = state} ->
        controls =
          state.pending_controls
          |> Map.keys()
          |> Enum.reject(&Map.has_key?(before.pending_controls, &1))

        notice =
          if before.auto_fallback_pending? and not state.auto_fallback_pending?,
            do: Map.take(before, [:auto_fallback_pending?, :auto_fallback_warned?])

        prompt =
          if state.pending_prompt_id != before.pending_prompt_id, do: state.pending_prompt_id

        answered =
          before.pending_client_requests
          |> Enum.find_value(fn {acp_id, entry} ->
            if not Map.has_key?(state.pending_client_requests, acp_id), do: entry
          end)

        last_write = %{prompt: prompt, controls: controls, notice: notice, answered: answered}
        put_elem(result, last, %{state | last_write: last_write})

      _other ->
        result
    end
  end

  defp route_outbound(%{"id" => _id, "method" => method} = msg, state)
       when is_binary(method) do
    with_session_scope(method, msg, state, fn state ->
      handle_request(method, msg, state)
    end)
  end

  defp route_outbound(%{"method" => method} = msg, state) when is_binary(method) do
    with_session_scope(method, msg, state, fn state ->
      handle_notification(method, msg, state)
    end)
  end

  defp route_outbound(%{"id" => _id} = msg, state) do
    state =
      state
      |> persist_current_session()
      |> then(&switch_to_client_request_session(msg["id"], &1))

    case Mapper.client_response(msg, state) do
      {:ok, data, state} ->
        {:ok, data, persist_current_session(state)}

      {:ok, messages, data, state} ->
        {:messages_and_write, messages, data, persist_current_session(state)}

      :unknown ->
        {:ok, :skip, persist_current_session(state)}
    end
  end

  defp route_outbound(_msg, state), do: {:ok, :skip, state}

  defp handle_request("session/new", %{"id" => _id, "params" => params}, state) do
    warn_unattached_mcp_servers("session/new", params, state)

    session_id =
      if state.managed? do
        params["sessionId"] || SessionStore.new_session_id()
      else
        state.session_id || params["sessionId"] || generated_session_id()
      end

    with {:ok, cwd} <- session_cwd(params, state),
         :ok <- authorize_workspace(cwd, :session_new, state),
         :ok <- new_session_available(session_id, state) do
      state = prepare_session_state(session_id, cwd, params, state)

      case start_session_process(session_id, cwd, params, :new, state) do
        {:ok, state} ->
          state = %{
            state
            | session_id: session_id,
              claude_session_id: if(state.managed?, do: state.claude_session_id, else: nil),
              cwd: cwd
          }

          reply_with_bypass_policy(params, state, fn state ->
            Mapper.session_result(state, session_id)
          end)

        {:error, reason, state} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp handle_request("initialize", %{"params" => params}, state) do
    {:ok, :skip, %{state | client_capabilities: params["clientCapabilities"] || %{}}}
  end

  defp handle_request("authenticate", %{"params" => %{"methodId" => method_id} = params}, state)
       when method_id in ["gateway", "gateway-bedrock"] do
    {:reply, %{}, %{state | gateway_auth: params}}
  end

  defp handle_request("authenticate", %{"params" => %{"methodId" => method_id}}, state)
       when method_id in ["claude-login", "claude-ai-login", "console-login"] do
    result =
      Enum.reduce_while(state.session_homes, :ok, fn {_id, opts}, :ok ->
        case RuntimeHome.refresh_auth(state.opts, Keyword.merge(state.opts, opts), :claude) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      :ok -> {:reply, %{}, state}
      {:error, reason} -> {:error, inspect(reason), state}
    end
  end

  defp handle_request("authenticate", %{"params" => %{"methodId" => method_id}}, state) do
    {:error, "Unsupported Claude auth method: #{method_id}", state}
  end

  defp handle_request("authenticate", _msg, state) do
    {:error, "authenticate requires params.methodId", state}
  end

  defp handle_request("logout", _msg, state) do
    state = %{state | gateway_auth: nil}

    if Keyword.get(state.opts, :logout_cli, true) do
      utility_opts =
        state.opts
        |> Keyword.put_new(:timeout, 5_000)
        |> Keyword.put_new(:max_output_bytes, 65_536)

      case Arbor.ACP.AdapterSupport.Subprocess.capture(
             ClaudeProtocol.cli_path(state.opts),
             ["auth", "logout"],
             utility_opts,
             __MODULE__
           ) do
        {:ok, _output, 0} ->
          {:reply, %{}, state}

        {:ok, output, status} ->
          {:error, "claude auth logout failed with status #{status}: #{String.trim(output)}",
           state}

        {:error, reason} ->
          {:error, "claude auth logout failed: #{inspect(reason)}", state}
      end
    else
      {:reply, %{}, state}
    end
  end

  defp handle_request("session/load", %{"params" => params}, state) do
    warn_unattached_mcp_servers("session/load", params, state)
    session_id = params["sessionId"] || state.session_id || generated_session_id()

    with {:ok, cwd} <- session_cwd(params, state),
         :ok <- authorize_workspace(cwd, :session_load, state),
         :ok <- session_restart_allowed(session_id, state),
         {:ok, _events} <-
           SessionStore.read_session_messages(
             native_session_id(state, session_id),
             params |> session_store_opts(state) |> Map.put(:cwd, cwd)
           ) do
      state = prepare_session_state(session_id, cwd, params, state)

      case start_session_process(session_id, cwd, params, :load, state) do
        {:ok, state} ->
          case load_persisted_session(session_id, cwd, params, state) do
            {:error, reason, failed} ->
              {:error, reason, close_session_process(failed, session_id)}

            result ->
              result
          end

        {:error, reason, state} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp handle_request("session/resume", %{"params" => params}, state) do
    warn_unattached_mcp_servers("session/resume", params, state)
    session_id = params["sessionId"] || state.session_id || generated_session_id()

    with {:ok, cwd} <- session_cwd(params, state),
         :ok <- authorize_workspace(cwd, :session_resume, state),
         :ok <- session_restart_allowed(session_id, state),
         :ok <- resume_history_available(session_id, cwd, params, state) do
      state = prepare_session_state(session_id, cwd, params, state)

      case start_session_process(session_id, cwd, params, :resume, state) do
        {:ok, state} ->
          state = %{
            state
            | session_id: session_id,
              claude_session_id:
                if(state.managed?, do: state.claude_session_id, else: session_id),
              cwd: cwd
          }

          reply_with_bypass_policy(params, state, fn state ->
            Mapper.session_result(state, session_id)
          end)

        {:error, reason, state} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp handle_request("session/close", %{"params" => %{"sessionId" => session_id}} = msg, state) do
    {messages, state} = cleanup_session(state, session_id)
    cleanup_reply(msg["id"], messages, state)
  end

  defp handle_request("session/close", _msg, state), do: {:reply, %{}, state}

  defp handle_request("session/list", %{"params" => params}, state) do
    case list_sessions(params, state) do
      {:ok, sessions, state} -> {:reply, %{"sessions" => sessions}, state}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp handle_request("session/list", _msg, state) do
    handle_request("session/list", %{"params" => %{}}, state)
  end

  defp handle_request(
         "session/delete",
         %{"params" => %{"sessionId" => session_id} = params} = msg,
         state
       ) do
    with {:ok, cwd} <- session_cwd(params, state),
         :ok <- authorize_workspace(cwd, :session_delete, state) do
      native_id = native_session_id(state, session_id)
      store_opts = params |> session_store_opts(state) |> Map.put(:cwd, cwd)
      {messages, state} = cleanup_session(state, session_id, false)

      case state.cleanup_result do
        {:error, _} ->
          cleanup_reply(msg["id"], messages, state)

        :ok ->
          case SessionStore.delete_session(native_id, store_opts) do
            :ok ->
              state =
                state |> release_session_home(session_id) |> clear_deleted_session(session_id)

              cleanup_reply(msg["id"], messages, state)

            {:error, reason} ->
              cleanup_error_reply(msg["id"], messages, reason, state)
          end
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp handle_request("session/delete", _msg, state) do
    {:error, "session/delete requires params.sessionId", state}
  end

  defp handle_request(
         "session/prompt",
         %{"id" => id, "params" => %{"sessionId" => session_id, "prompt" => prompt}},
         state
       ) do
    case require_known_session(session_id, state) do
      {:ok, state} ->
        with_pending_auto_notice(state, fn state ->
          if state.pending_prompt_id do
            case ClaudeProtocol.user_message(session_id || state.session_id, prompt) do
              {:ok, message} -> {:ok, :skip, enqueue_prompt(state, id, session_id, message)}
              {:error, reason} -> {:error, reason, state}
            end
          else
            start_prompt(id, session_id, prompt, state)
          end
        end)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp handle_request("session/set_mode", %{"params" => %{"modeId" => mode_id}}, state) do
    available = Mapper.modes_result(state)["availableModes"]

    if Enum.any?(available, &(&1["id"] == mode_id)) do
      requested = encode_permission_mode(mode_id)
      # Auto is always in the catalog, so a model that cannot run it settles on
      # the fallback mode here rather than refusing the request.
      effective = Mapper.current_mode(%{state | permission_mode: requested})
      request_id = control_id("set_permission_mode")

      state = %{
        state
        | permission_mode: effective,
          pending_controls: Map.put(state.pending_controls, request_id, :set_permission_mode)
      }

      data =
        ClaudeProtocol.control_request(request_id, %{
          "subtype" => "set_permission_mode",
          "mode" => effective
        })
        |> ClaudeProtocol.line()

      reply = %{"modes" => Mapper.modes_result(state)}

      if effective == requested do
        {:reply_and_write, reply, data, state}
      else
        {notice, state} = Mapper.auto_fallback_messages(state)
        {:messages_and_reply_and_write, notice ++ [Mapper.mode_update(state)], reply, data, state}
      end
    else
      {:error, "Unsupported Claude permission mode: #{mode_id}", state}
    end
  end

  defp handle_request(
         "session/set_config_option",
         %{"params" => %{"configId" => "model", "value" => model}},
         state
       ) do
    model_request_id = control_id("set_model")

    state = %{
      state
      | model: model,
        pending_controls: Map.put(state.pending_controls, model_request_id, :set_model)
    }

    model_write =
      ClaudeProtocol.control_request(model_request_id, %{
        "subtype" => "set_model",
        "model" => model
      })
      |> ClaudeProtocol.line()

    # The new model may invalidate the session's mode: one outside the catalog
    # clamps to `default`, and Auto on a model without Auto support clamps to
    # the fallback mode with a client-visible notice.
    {writes, messages, state} =
      if Mapper.current_mode(state) != state.permission_mode do
        auto_fallback? = Mapper.auto_fallback?(state)
        mode = Mapper.current_mode(state)
        mode_request_id = control_id("set_permission_mode")

        mode_write =
          ClaudeProtocol.control_request(mode_request_id, %{
            "subtype" => "set_permission_mode",
            "mode" => mode
          })
          |> ClaudeProtocol.line()

        state = %{
          state
          | permission_mode: mode,
            pending_controls:
              Map.put(state.pending_controls, mode_request_id, :set_permission_mode)
        }

        {messages, state} =
          if auto_fallback? do
            {notice, state} = Mapper.auto_fallback_messages(state)
            {[Mapper.mode_update(state) | notice], state}
          else
            {[], state}
          end

        {[model_write, mode_write], messages, state}
      else
        {[model_write], [], state}
      end

    reply = %{"configOptions" => Mapper.config_options(state)}

    if messages == [] do
      {:reply_and_write, reply, writes, state}
    else
      {:messages_and_reply_and_write, messages, reply, writes, state}
    end
  end

  defp handle_request(
         "session/set_config_option",
         %{"params" => %{"configId" => "mode", "value" => mode}},
         state
       ) do
    handle_request("session/set_mode", %{"params" => %{"modeId" => mode}}, state)
  end

  defp handle_request(
         "session/set_config_option",
         %{"params" => %{"configId" => "permission_mode", "value" => mode}},
         state
       ) do
    handle_request("session/set_mode", %{"params" => %{"modeId" => mode}}, state)
  end

  defp handle_request(
         "session/set_config_option",
         %{"params" => %{"configId" => "effort", "value" => effort}},
         state
       ) do
    request_id = control_id("apply_flag_settings")

    state = %{
      state
      | effort: effort,
        pending_controls: Map.put(state.pending_controls, request_id, :apply_flag_settings)
    }

    data =
      ClaudeProtocol.control_request(request_id, %{
        "subtype" => "apply_flag_settings",
        "settings" => %{"effortLevel" => to_sdk_effort_level(effort)}
      })
      |> ClaudeProtocol.line()

    {:reply_and_write, %{"configOptions" => Mapper.config_options(state)}, data, state}
  end

  defp handle_request(
         "session/set_config_option",
         %{"params" => %{"configId" => "fast"} = params},
         state
       ) do
    case resolve_fast_mode_enabled(params) do
      {:ok, fast_mode_enabled} ->
        request_id = control_id("apply_flag_settings")

        state = %{
          state
          | fast_mode_enabled: fast_mode_enabled,
            pending_controls: Map.put(state.pending_controls, request_id, :apply_flag_settings)
        }

        data =
          ClaudeProtocol.control_request(request_id, %{
            "subtype" => "apply_flag_settings",
            "settings" => %{"fastMode" => fast_mode_enabled}
          })
          |> ClaudeProtocol.line()

        {:reply_and_write, %{"configOptions" => Mapper.config_options(state)}, data, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp handle_request(
         "session/set_config_option",
         %{"params" => %{"configId" => "agent", "value" => agent}},
         state
       ) do
    request_id = control_id("apply_flag_settings")
    agent = to_string(agent)
    sdk_agent = if agent == "default", do: nil, else: agent

    state = %{
      state
      | current_agent: agent,
        pending_controls: Map.put(state.pending_controls, request_id, :apply_flag_settings)
    }

    data =
      ClaudeProtocol.control_request(request_id, %{
        "subtype" => "apply_flag_settings",
        "settings" => %{"agent" => sdk_agent}
      })
      |> ClaudeProtocol.line()

    {:reply_and_write, %{"configOptions" => Mapper.config_options(state)}, data, state}
  end

  defp handle_request("session/set_config_option", _msg, state) do
    {:reply, %{"configOptions" => Mapper.config_options(state)}, state}
  end

  defp handle_request(_method, _msg, state), do: {:ok, :skip, state}

  defp load_persisted_session(session_id, cwd, params, state) do
    state = %{
      state
      | session_id: session_id,
        claude_session_id: native_session_id(state, session_id),
        cwd: cwd
    }

    case SessionStore.read_session_messages(
           native_session_id(state, session_id),
           params |> session_store_opts(state) |> Map.put(:cwd, cwd)
         ) do
      {:ok, events} ->
        {messages, state} = Mapper.replay_messages(events, state)

        # Same policy pair as session/new and session/resume: a loaded session
        # can inherit a bypass or Auto mode the model cannot support, so both
        # have to be clamped here too.
        {state, bypass_write} = apply_bypass_policy(params, state)
        {state, auto_write} = apply_auto_mode_policy(state)
        result = Mapper.session_result(state, session_id)

        case Enum.reject([bypass_write, auto_write], &is_nil/1) do
          [] -> {:messages_and_reply, messages, result, state}
          writes -> {:messages_and_reply_and_write, messages, result, writes, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # Mirrors claude-agent-acp#1129: a host that never uses bypassPermissions may
  # opt a session out by sending `_meta.claudeCode.options.allowDangerouslySkipPermissions:
  # false` on session/new, and again on session/load or session/resume. It removes
  # the mode from the catalog and refuses it in session/set_mode. `true` cannot
  # override the adapter's own `allow_dangerously_skip_permissions` option. The
  # CLI flag itself is fixed at spawn time, so an active bypass mode is clamped
  # to default through a set_permission_mode control instead.
  defp apply_bypass_policy(params, state) do
    opted_out? =
      get_in(params, ["_meta", "claudeCode", "options", "allowDangerouslySkipPermissions"]) ==
        false

    state = %{state | bypass_allowed?: not opted_out?}

    if opted_out? and state.permission_mode == "bypassPermissions" do
      request_id = control_id("set_permission_mode")

      state = %{
        state
        | permission_mode: "default",
          pending_controls: Map.put(state.pending_controls, request_id, :set_permission_mode)
      }

      data =
        ClaudeProtocol.control_request(request_id, %{
          "subtype" => "set_permission_mode",
          "mode" => "default"
        })
        |> ClaudeProtocol.line()

      {state, data}
    else
      {state, nil}
    end
  end

  # Mirrors claude-agent-acp#1025: a session that opens in Auto on a model
  # without Auto support settles on the fallback mode and syncs the SDK, so
  # Claude is never left running a mode it would reject. The notice is held
  # until the first prompt — the client cannot receive a session update for a
  # session id `session/new` has not returned yet.
  defp apply_auto_mode_policy(state) do
    if Mapper.auto_fallback?(state) do
      mode = Mapper.auto_fallback_mode()
      request_id = control_id("set_permission_mode")

      state = %{
        state
        | permission_mode: mode,
          auto_fallback_pending?: true,
          pending_controls: Map.put(state.pending_controls, request_id, :set_permission_mode)
      }

      data =
        ClaudeProtocol.control_request(request_id, %{
          "subtype" => "set_permission_mode",
          "mode" => mode
        })
        |> ClaudeProtocol.line()

      {state, data}
    else
      {state, nil}
    end
  end

  defp reply_with_bypass_policy(params, state, result_fun) do
    {state, bypass_write} = apply_bypass_policy(params, state)
    {state, auto_write} = apply_auto_mode_policy(state)

    case Enum.reject([bypass_write, auto_write], &is_nil/1) do
      [] -> {:reply, result_fun.(state), state}
      writes -> {:reply_and_write, result_fun.(state), writes, state}
    end
  end

  # Delivers an Auto-mode fallback notice held since `session/new` alongside
  # whatever the wrapped request produces. A failed request keeps the notice
  # pending so it is not lost.
  defp with_pending_auto_notice(state, fun) do
    {notice, noticed} = Mapper.auto_fallback_pending_messages(state)

    case fun.(noticed) do
      result when notice == [] -> result
      {:ok, :skip, new_state} -> {:messages, notice, new_state}
      {:ok, data, new_state} -> {:messages_and_write, notice, data, new_state}
      {:error, reason, _new_state} -> {:error, reason, state}
    end
  end

  defp handle_notification("session/cancel", %{"params" => params}, state) do
    session_id = params["sessionId"] || state.active_prompt_session_id || state.session_id
    {cancelled_messages, state} = cancel_queued_prompts(state, session_id)
    request_id = control_id("interrupt")

    state = %{
      state
      | pending_controls: Map.put(state.pending_controls, request_id, :interrupt),
        background_subagents: MapSet.new(),
        deferred_result: nil
    }

    data =
      ClaudeProtocol.control_request(request_id, %{"subtype" => "interrupt"})
      |> ClaudeProtocol.line()

    if cancelled_messages == [] do
      {:ok, data, state}
    else
      {:messages_and_write, cancelled_messages, data, state}
    end
  end

  defp handle_notification(_method, _msg, state), do: {:ok, :skip, state}

  @impl true
  def translate_inbound(line, state) do
    trimmed = String.trim(line)

    with false <- trimmed == "",
         {:ok, event} <- Jason.decode(trimmed) do
      {messages, writes, state} = Mapper.reduce_message(event, state)
      return_inbound(messages, writes, state)
    else
      true ->
        {:skip, state}

      {:error, _reason} ->
        Logger.debug("[ClaudeSDK Adapter] Non-JSON line: #{String.slice(trimmed, 0, 120)}")
        {:skip, state}
    end
  end

  defp return_inbound([], [], state), do: {:skip, state}
  defp return_inbound([], [write], state), do: {:skip_and_write, write, state}
  defp return_inbound([], writes, state), do: {:skip_and_write, writes, state}
  defp return_inbound(messages, [], state), do: {:messages, messages, state}
  defp return_inbound(messages, writes, state), do: {:messages_and_write, messages, writes, state}

  defp control_id(prefix),
    do: "ex_mcp_#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  defp generated_session_id do
    "claude_sdk_#{System.unique_integer([:positive, :monotonic])}"
  end

  # Session `mcpServers` cannot reach a Claude Code process that is already
  # running. Say so for the ones the launch options did not configure, which
  # would otherwise go missing silently.
  defp warn_unattached_mcp_servers(method, params, state) do
    case MCPConfig.unattached_servers((params || %{})["mcpServers"], state.opts) do
      [] ->
        :ok

      names ->
        Logger.warning(
          "Claude SDK adapter: #{method} asked for MCP servers #{inspect(names)}, " <>
            "which are not attached. Claude Code takes MCP servers only at launch; " <>
            "pass them through the :mcp_servers or :mcp_config_path adapter option."
        )
    end
  end

  defp session_store_opts(params, state) do
    params = params || %{}

    %{
      cwd: params["cwd"] || params[:cwd] || state.cwd || Keyword.get(state.opts, :cwd),
      cursor: params["cursor"] || params[:cursor],
      limit: params["limit"] || params[:limit],
      offset: params["offset"] || params[:offset],
      claude_config_dir:
        Keyword.get(
          session_home_opts(state, params["sessionId"] || state.session_id),
          :claude_config_dir,
          Keyword.get(state.opts, :claude_config_dir)
        ),
      env: Keyword.get(state.opts, :env, []),
      include_worktrees: false,
      session_id: params["sessionId"] || state.session_id || Keyword.get(state.opts, :session_id),
      trust_workspace_config: Keyword.get(state.opts, :trust_workspace_config, false)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp session_cwd(params, state) do
    cwd = (params || %{})["cwd"] || state.cwd || Keyword.get(state.opts, :cwd)

    if is_binary(cwd) and cwd != "" and Path.type(cwd) == :absolute do
      {:ok, WorkspacePath.canonical(cwd)}
    else
      {:error, "Workspace paths must be absolute"}
    end
  end

  defp authorize_workspace(path, kind, state) do
    context = %{kind: kind, adapter: __MODULE__}

    case Keyword.get(state.opts, :authorize_workspace) do
      callback when is_function(callback, 2) ->
        callback
        |> safe_authorize(path, context)
        |> authorization_result("Workspace path is not authorized")

      callback when is_function(callback, 1) ->
        callback
        |> safe_authorize(path)
        |> authorization_result("Workspace path is not authorized")

      nil ->
        if within_workspace_roots?(path, state),
          do: :ok,
          else: {:error, "Workspace path is not authorized"}

      _invalid ->
        {:error, "Invalid workspace authorization callback"}
    end
  end

  defp authorization_result(result, _message) when result in [:ok, true], do: :ok
  defp authorization_result({:ok, _value}, _message), do: :ok
  defp authorization_result(_result, message), do: {:error, message}

  defp within_workspace_roots?(path, state) do
    roots =
      case Keyword.get(state.opts, :workspace_roots) do
        roots when is_list(roots) -> roots
        nil -> [Keyword.get(state.opts, :cwd) || state.workspace_root]
        root -> [root]
      end

    Enum.any?(roots, fn
      root when is_binary(root) and root != "" ->
        Path.type(root) == :absolute and WorkspacePath.within?(path, root)

      _invalid ->
        false
    end)
  end

  defp safe_authorize(callback, path, context) do
    callback.(path, context)
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp safe_authorize(callback, path) do
    callback.(path)
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp maybe_switch_session(%{"params" => %{"sessionId" => session_id}}, state)
       when is_binary(session_id) and session_id != "" do
    if Map.has_key?(state.session_processes, session_id),
      do: switch_session(state, session_id),
      else: state
  end

  defp maybe_switch_session(_msg, state), do: state

  defp require_known_session(_session_id, %{managed?: false} = state), do: {:ok, state}

  defp require_known_session(session_id, state)
       when is_binary(session_id) and session_id != "" do
    if Map.has_key?(state.session_processes, session_id) do
      {:ok, switch_session(state, session_id)}
    else
      {:error, "Unknown Claude session"}
    end
  end

  defp require_known_session(_session_id, _state), do: {:error, "Unknown Claude session"}

  defp with_session_scope(method, msg, state, fun) when method in @session_scoped_methods do
    case get_in(msg, ["params", "sessionId"]) do
      session_id when is_binary(session_id) and session_id != "" ->
        case require_known_session(session_id, state) do
          {:ok, state} -> fun.(state)
          {:error, reason} -> {:error, reason, state}
        end

      _missing ->
        fun.(state)
    end
  end

  defp with_session_scope(_method, _msg, state, fun), do: fun.(state)

  defp parent_session_fields(session_id, state) when is_binary(session_id) do
    case Map.get(state.session_processes, session_id) do
      %{fields: fields} when is_map(fields) -> fields
      _missing -> Map.take(reset_session_fields(state), @session_fields)
    end
  end

  defp parent_session_fields(_session_id, state),
    do: Map.take(reset_session_fields(state), @session_fields)

  defp switch_to_client_request_session(id, state) do
    case find_session_for_client_request(id, state) do
      nil -> state
      session_id -> switch_session(state, session_id)
    end
  end

  defp find_session_for_client_request(id, state) do
    Enum.find_value(state.session_processes, fn {session_id, entry} ->
      pending = Map.get(entry.fields, :pending_client_requests) || %{}
      if Map.has_key?(pending, id), do: session_id
    end)
  end

  defp prepare_session_state(session_id, cwd, _params, %{managed?: false} = state) do
    %{state | session_id: session_id, cwd: cwd}
  end

  defp prepare_session_state(session_id, cwd, params, state) do
    state = persist_current_session(state)

    state =
      if Map.has_key?(state.session_processes, session_id) do
        switch_session(state, session_id)
      else
        reset_session_fields(state)
      end

    {state, _write} = apply_bypass_policy(params, %{state | session_id: session_id, cwd: cwd})
    state
  end

  defp switch_session(state, session_id) do
    if state.session_id == session_id do
      state
    else
      state
      |> persist_current_session()
      |> load_session_fields(session_id)
    end
  end

  defp persist_current_session(%{session_id: session_id} = state)
       when is_binary(session_id) do
    case Map.get(state.session_processes, session_id) do
      nil ->
        state

      entry ->
        %{
          state
          | session_processes:
              Map.put(state.session_processes, session_id, %{
                entry
                | fields: Map.take(state, @session_fields)
              })
        }
    end
  end

  defp persist_current_session(state), do: state

  defp load_session_fields(state, session_id) do
    case Map.get(state.session_processes, session_id) do
      %{handle: handle, fields: fields} ->
        state
        |> Map.merge(fields)
        |> Map.put(:port, handle)

      _missing ->
        state
    end
  end

  defp start_session_process(_session_id, _cwd, _params, _kind, %{managed?: false} = state),
    do: {:ok, state}

  defp start_session_process(session_id, cwd, _params, kind, state) do
    had_home? = Map.has_key?(state.session_homes, session_id)
    state = state |> persist_current_session() |> ensure_session_home(session_id)
    opts = session_process_opts(state, cwd, session_id, kind)

    result =
      case cli_command(opts) do
        {:error, reason} ->
          {:error, format_command_error(reason), state}

        {cmd, args} ->
          case RuntimeHome.seed_auth(state.opts, opts, :claude) do
            :ok -> open_session_process(session_id, cmd, args, opts, state)
            {:error, reason} -> {:error, inspect(reason), state}
          end
      end

    case result do
      {:error, reason, failed} when not had_home? ->
        if Map.has_key?(failed.session_processes, session_id) do
          {:error, reason, failed}
        else
          {:error, reason, release_session_home(failed, session_id)}
        end

      result ->
        result
    end
  end

  defp ensure_session_home(state, session_id) do
    if Map.has_key?(state.session_homes, session_id) do
      state
    else
      opts =
        state.opts |> Keyword.put(:_runtime_home_session, session_id) |> Keyword.delete(:resume)

      home = opts |> RuntimeHome.put_opt(:claude) |> Keyword.take([:claude_config_dir])
      %{state | session_homes: Map.put(state.session_homes, session_id, home)}
    end
  end

  defp session_store_homes(state) do
    [
      Keyword.get(state.opts, :claude_config_dir)
      | Enum.map(state.session_homes, fn {_id, opts} -> Keyword.get(opts, :claude_config_dir) end)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp relocate_fork(session_id, cwd, parent_opts, home_opts) do
    source_home = SessionStore.config_dir(parent_opts)
    target_home = Keyword.get(home_opts, :claude_config_dir, source_home)

    if source_home == target_home do
      :ok
    else
      opts = parent_opts |> Map.put(:offset, 0) |> Map.delete(:cursor) |> Map.delete(:limit)

      with {:ok, sessions} <- SessionStore.list_sessions(opts),
           %{"path" => source} <- Enum.find(sessions, &(&1["sessionId"] == session_id)),
           target_dir = Path.join([target_home, "projects", SessionStore.project_key(cwd)]),
           true <- WorkspacePath.within?(target_dir, target_home),
           :ok <- File.mkdir_p(target_dir),
           {:ok, contents} <- File.read(source),
           :ok <-
             File.write(Path.join(target_dir, session_id <> ".jsonl"), contents, [
               :write,
               :exclusive
             ]),
           :ok <-
             retire_fork_source(
               session_id,
               parent_opts,
               Path.join(target_dir, session_id <> ".jsonl")
             ) do
        :ok
      else
        {:error, reason} -> {:error, inspect(reason)}
        _missing_or_unsafe -> {:error, "Forked Claude session could not be moved to its home"}
      end
    end
  end

  defp retire_fork_source(session_id, opts, target) do
    case SessionStore.delete_session(session_id, opts) do
      :ok ->
        :ok

      {:error, _} = error ->
        File.rm(target)
        error
    end
  end

  defp native_session_id(state, session_id) do
    case get_in(state.session_processes, [session_id, :fields, :claude_session_id]) do
      id when is_binary(id) ->
        id

      _missing ->
        case List.keyfind(state.session_aliases, session_id, 0) do
          {^session_id, native} ->
            native

          nil ->
            if state.session_id == session_id and is_binary(state.claude_session_id),
              do: state.claude_session_id,
              else: session_id
        end
    end
  end

  defp remember_closed_alias(state, session_id) do
    native = native_session_id(state, session_id)

    if native != session_id and SessionStore.valid_session_id?(native) do
      aliases = [{session_id, native} | List.keydelete(state.session_aliases, session_id, 0)]

      {kept, _bytes} =
        Enum.reduce_while(Enum.take(aliases, 1_024), {[], 0}, fn entry, {kept, bytes} ->
          next = bytes + :erlang.external_size(entry)
          if next <= 1_048_576, do: {:cont, {[entry | kept], next}}, else: {:halt, {kept, bytes}}
        end)

      %{state | session_aliases: Enum.reverse(kept)}
    else
      state
    end
  end

  defp resume_history_available(_id, _cwd, _params, %{managed?: false}), do: :ok

  defp resume_history_available(id, cwd, params, state) do
    if Map.has_key?(state.session_processes, id) do
      :ok
    else
      case SessionStore.read_session_messages(
             native_session_id(state, id),
             params |> session_store_opts(state) |> Map.put(:cwd, cwd)
           ) do
        {:ok, _history} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp session_process_opts(state, cwd, session_id, kind) do
    opts =
      state.opts
      |> absolute_mcp_paths()
      |> Keyword.put(:cwd, cwd)
      |> Keyword.put(:_runtime_home_session, session_id)
      |> Keyword.delete(:resume)
      |> Keyword.delete(:session_id)
      |> Keyword.merge(session_home_opts(state, session_id))
      |> session_preferences(state)
      |> constrain_child_permissions(state)

    native_id = native_session_id(state, session_id)

    cond do
      kind in [:load, :resume, :fork] and SessionStore.valid_session_id?(native_id) ->
        Keyword.put(opts, :resume, native_id)

      kind == :new ->
        native_id =
          if SessionStore.valid_session_id?(session_id),
            do: session_id,
            else: SessionStore.new_session_id()

        Keyword.put(opts, :session_id, native_id)

      true ->
        opts
    end
  end

  defp absolute_mcp_paths(opts) do
    base = Keyword.get(opts, :cwd) || File.cwd!()

    if Keyword.has_key?(opts, :mcp_config_path) do
      Keyword.update!(opts, :mcp_config_path, fn paths ->
        Enum.map(List.wrap(paths), fn
          path when is_binary(path) -> Path.expand(path, base)
          other -> other
        end)
      end)
    else
      opts
    end
  end

  defp session_home_opts(state, session_id) do
    case Map.get(state.session_homes, session_id) do
      opts when is_list(opts) -> opts
      _missing -> []
    end
  end

  defp session_preferences(opts, state) do
    Enum.reduce([:model, :permission_mode, :effort, :fast_mode, :agent], opts, fn option, opts ->
      field =
        case option do
          :fast_mode -> :fast_mode_enabled
          :agent -> :current_agent
          field -> field
        end

      case {option, Map.get(state, field)} do
        {:agent, "default"} -> Keyword.delete(opts, :agent)
        {_option, nil} -> opts
        {_option, value} -> Keyword.put(opts, option, value)
      end
    end)
  end

  defp new_session_available(_id, %{managed?: false}), do: :ok

  defp new_session_available(id, state) do
    if Map.has_key?(state.session_processes, id),
      do: {:error, "Claude session id is already open"},
      else: :ok
  end

  defp session_restart_allowed(_session_id, %{managed?: false}), do: :ok

  defp session_restart_allowed(session_id, state) do
    fields =
      if state.session_id == session_id,
        do: state,
        else: get_in(state.session_processes, [session_id, :fields]) || %{}

    cond do
      Map.get(fields, :pending_prompt_id) ->
        {:error, "Claude session has an active prompt"}

      not SessionStore.valid_session_id?(native_session_id(state, session_id)) ->
        {:error, "Unknown native Claude session identity"}

      true ->
        :ok
    end
  end

  defp constrain_child_permissions(opts, %{bypass_allowed?: false} = state) do
    mode = state.permission_mode || "default"
    mode = if mode == "bypassPermissions", do: "default", else: mode

    opts
    |> Keyword.put(:permission_mode, mode)
    |> Keyword.put(:allow_dangerously_skip_permissions, false)
  end

  defp constrain_child_permissions(opts, _state), do: opts

  defp open_session_process(session_id, cmd, args, opts, state) do
    state = close_session_process(state, session_id)

    case state.cleanup_result do
      :ok -> do_open_session_process(session_id, cmd, args, opts, state)
      {:error, reason} -> {:error, inspect(reason), state}
    end
  end

  defp do_open_session_process(session_id, cmd, args, opts, state) do
    case PortRunner.open(cmd, args, opts, __MODULE__) do
      {:ok, handle} ->
        [actor] = Subprocess.linked_processes(handle)
        monitor = Process.monitor(actor)
        request_id = control_id("initialize")

        entry = %{
          handle: handle,
          monitor: monitor,
          fields:
            Map.take(
              %{
                state
                | session_id: session_id,
                  claude_session_id: Keyword.get(opts, :session_id) || Keyword.get(opts, :resume),
                  cwd: Keyword.get(opts, :cwd)
              },
              @session_fields
            )
        }

        state = %{
          state
          | port: handle,
            session_id: session_id,
            claude_session_id: Keyword.get(opts, :session_id) || Keyword.get(opts, :resume),
            cwd: Keyword.get(opts, :cwd),
            pending_controls: Map.put(state.pending_controls, request_id, :initialize),
            session_processes: Map.put(state.session_processes, session_id, entry)
        }

        init =
          opts
          |> ClaudeProtocol.initialize_request(request_id)
          |> ClaudeProtocol.line()

        flags_id = control_id("apply_flag_settings")

        flags =
          ClaudeProtocol.control_request(flags_id, %{
            "subtype" => "apply_flag_settings",
            "settings" => %{"fastMode" => Keyword.get(opts, :fast_mode, false)}
          })
          |> ClaudeProtocol.line()

        state = %{
          state
          | pending_controls: Map.put(state.pending_controls, flags_id, :apply_flag_settings)
        }

        case PortRunner.command(handle, [init, flags]) do
          :ok ->
            {:ok, persist_current_session(state)}

          {:error, reason} ->
            {:error, inspect(reason), forget_session_process(state, session_id, handle)}
        end

      {:error, reason} ->
        {:error, inspect(reason), state}
    end
  end

  defp reset_session_fields(state) do
    blank = %__MODULE__{
      opts: state.opts,
      managed?: state.managed?,
      client_capabilities: state.client_capabilities,
      gateway_auth: state.gateway_auth,
      session_processes: state.session_processes,
      model: Keyword.get(state.opts, :model),
      permission_mode:
        encode_permission_mode(Keyword.get(state.opts, :permission_mode, :default)),
      effort: Keyword.get(state.opts, :effort),
      fast_mode_enabled: Keyword.get(state.opts, :fast_mode, false),
      current_agent: Keyword.get(state.opts, :agent, "default")
    }

    Map.merge(state, Map.take(blank, @session_fields))
  end

  defp close_session_process(state, session_id) do
    case Map.get(state.session_processes, session_id) do
      %{handle: handle} -> forget_session_process(state, session_id, handle)
      _missing -> state
    end
  end

  defp forget_session_process(state, session_id, handle) do
    state = persist_current_session(state)

    case PortRunner.close(handle) do
      :ok ->
        case Map.get(state.session_processes, session_id) do
          %{monitor: monitor} when is_reference(monitor) -> Process.demonitor(monitor, [:flush])
          _other -> :ok
        end

        state = remember_closed_alias(state, session_id)
        processes = Map.delete(state.session_processes, session_id)

        %{
          state
          | port: if(state.port == handle, do: nil, else: state.port),
            session_processes: processes
        }
        |> refresh_cleanup_result()

      {:error, reason} ->
        processes =
          Map.update!(state.session_processes, session_id, &Map.put(&1, :cleanup_error, reason))

        %{state | session_processes: processes, cleanup_result: {:error, reason}}
    end
  end

  defp find_session_event(message, state) do
    Enum.find_value(state.session_processes, fn {session_id, entry} ->
      case PortRunner.event(entry.handle, message) do
        :ignore -> nil
        event -> {session_id, entry.handle, event}
      end
    end)
  end

  defp find_session_by_monitor(state, monitor) do
    Enum.find_value(state.session_processes, fn {session_id, entry} ->
      if entry.monitor == monitor, do: {session_id, entry.handle}
    end)
  end

  defp inbound_to_adapter_message({:messages, messages, state}, _handle),
    do: {:messages, messages, persist_current_session(state)}

  defp inbound_to_adapter_message({:messages_and_write, messages, data, state}, handle) do
    _ = PortRunner.command(handle, data)
    {:messages, messages, persist_current_session(state)}
  end

  defp inbound_to_adapter_message({:skip_and_write, data, state}, handle) do
    _ = PortRunner.command(handle, data)
    {:skip, persist_current_session(state)}
  end

  defp inbound_to_adapter_message({:skip, state}, _handle),
    do: {:skip, persist_current_session(state)}

  defp deliver_managed(result, msg) do
    state = elem(result, tuple_size(result) - 1)

    if state.managed? and writes_data?(result) do
      data = write_payload(result)

      case write_session_data(data, state) do
        :ok ->
          drop_write(result)

        {:error, reason} ->
          retired =
            case outbound_write_failed(msg, reason, state) do
              {:write, replacement, retired_state} ->
                _ = write_session_data(replacement, retired_state)
                retired_state

              retired_state ->
                retired_state
            end

          {:error, inspect(reason), retired}
      end
    else
      result
    end
  end

  defp writes_data?({:ok, data, _state}), do: data not in [:skip, :pending]
  defp writes_data?({:reply_and_write, _result, _data, _state}), do: true
  defp writes_data?({:messages_and_write, _messages, _data, _state}), do: true
  defp writes_data?({:pending_and_write, _data, _state}), do: true
  defp writes_data?({:messages_and_reply_and_write, _messages, _result, _data, _state}), do: true
  defp writes_data?(_result), do: false

  defp write_payload({:ok, data, _state}), do: data
  defp write_payload({:reply_and_write, _result, data, _state}), do: data
  defp write_payload({:messages_and_write, _messages, data, _state}), do: data
  defp write_payload({:pending_and_write, data, _state}), do: data
  defp write_payload({:messages_and_reply_and_write, _messages, _result, data, _state}), do: data

  defp drop_write({:ok, _data, state}), do: {:ok, :skip, persist_current_session(state)}

  defp drop_write({:reply_and_write, result, _data, state}),
    do: {:reply, result, persist_current_session(state)}

  defp drop_write({:messages_and_write, messages, _data, state}),
    do: {:messages, messages, persist_current_session(state)}

  defp drop_write({:pending_and_write, _data, state}),
    do: {:ok, :pending, persist_current_session(state)}

  defp drop_write({:messages_and_reply_and_write, messages, result, _data, state}),
    do: {:messages_and_reply, messages, result, persist_current_session(state)}

  defp write_session_data(data, state) do
    case session_handle(state) do
      nil -> {:error, :no_active_claude_session}
      handle -> PortRunner.command(handle, data)
    end
  end

  defp session_handle(%{port: handle}) when not is_nil(handle), do: handle

  defp session_handle(%{session_id: session_id, session_processes: processes}) do
    case Map.get(processes, session_id) do
      %{handle: handle} -> handle
      _missing -> nil
    end
  end

  defp format_command_error({:invalid_option, key, message}),
    do: "invalid #{key}: #{message}"

  defp format_command_error(reason), do: inspect(reason)

  defp put_fork_message_id(opts, params) do
    case fork_message_id(params) do
      nil -> opts
      message_id -> Map.put(opts, :fork_message_id, message_id)
    end
  end

  # The fork point a client attaches to `session/fork`, in the shape
  # claude-agent-acp reads (`forkPoint` in its `src/fork-session.ts`): an
  # explicitly versioned object under `_meta.jetbrains.air.fork`. A missing
  # object, any other version, a missing id and a blank id all mean "no fork
  # point", which is the whole-session fork ExMCP has always performed.
  defp fork_message_id(params) do
    case fork_meta(params) do
      %{"version" => @fork_meta_version, "messageId" => message_id}
      when is_binary(message_id) ->
        blank_to_nil(String.trim(message_id))

      _ ->
        nil
    end
  end

  defp fork_meta(params) do
    Enum.reduce_while(@fork_meta_path, params, fn key, acc ->
      case acc do
        %{^key => value} -> {:cont, value}
        _ -> {:halt, nil}
      end
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp clear_deleted_session(state, session_id) do
    native = native_session_id(state, session_id)

    aliases =
      Enum.reject(state.session_aliases, fn {id, target} ->
        id == session_id or target == native
      end)

    clear_deleted_session_fields(%{state | session_aliases: aliases}, session_id)
  end

  defp clear_deleted_session_fields(%{session_id: session_id} = state, session_id) do
    %{
      state
      | session_id: nil,
        claude_session_id: nil,
        pending_prompt_id: nil,
        active_prompt_session_id: nil,
        prompt_queue: PromptQueue.new(),
        text_acc: [],
        thinking_acc: [],
        thinking_blocks: [],
        current_block_type: nil,
        current_assistant_text_streamed?: false,
        stream_message_id: nil,
        tool_calls: %{},
        background_subagents: MapSet.new(),
        deferred_result: nil
    }
  end

  defp clear_deleted_session_fields(state, _session_id), do: state

  defp start_prompt(id, session_id, prompt, state) do
    case ClaudeProtocol.user_message(session_id || state.session_id, prompt) do
      {:ok, message} ->
        state =
          %{
            state
            | pending_prompt_id: id,
              active_prompt_session_id: session_id || state.session_id,
              session_id: session_id || state.session_id,
              text_acc: [],
              thinking_acc: [],
              thinking_blocks: [],
              current_block_type: nil,
              current_assistant_text_streamed?: false,
              stream_message_id: nil,
              tool_calls: %{},
              background_subagents: MapSet.new(),
              deferred_result: nil,
              turn_model_usage: %{}
          }

        {:ok, ClaudeProtocol.line(message), state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp enqueue_prompt(state, id, session_id, message) do
    queued = %{id: id, session_id: session_id, message: message}
    %{state | prompt_queue: PromptQueue.enqueue(state.prompt_queue, queued)}
  end

  defp cancel_queued_prompts(state, nil), do: {[], state}

  defp cancel_queued_prompts(state, session_id) do
    {cancelled, remaining} =
      PromptQueue.split(state.prompt_queue, &(&1.session_id == session_id))

    messages =
      Enum.map(cancelled, fn %{id: id} ->
        Envelope.response(id, %{"stopReason" => "cancelled"})
      end)

    {messages, %{state | prompt_queue: remaining}}
  end

  defp cleanup_reply(_id, [], %{cleanup_result: :ok} = state), do: {:reply, %{}, state}

  defp cleanup_reply(_id, messages, %{cleanup_result: :ok} = state),
    do: {:messages_and_reply, messages, %{}, state}

  defp cleanup_reply(id, messages, %{cleanup_result: {:error, reason}} = state),
    do: cleanup_error_reply(id, messages, reason, state)

  defp cleanup_error_reply(_id, [], reason, state),
    do: {:error, cleanup_error_text(reason), state}

  defp cleanup_error_reply(id, messages, reason, state),
    do:
      {:messages,
       messages ++ [Envelope.error(id, -32_603, "Claude cleanup failed: #{inspect(reason)}")],
       state}

  defp cleanup_error_text(reason) when is_binary(reason), do: reason
  defp cleanup_error_text(reason), do: inspect(reason)

  defp cleanup_session(state, session_id, release_home? \\ true) do
    {queued_messages, state} = cancel_queued_prompts(state, session_id)
    {active_messages, state} = cancel_active_prompt(state, session_id)

    state = close_session_process(state, session_id)

    state = if release_home?, do: release_session_home(state, session_id), else: state

    state =
      if state.session_id == session_id do
        %{
          state
          | session_id: nil,
            claude_session_id: nil,
            text_acc: [],
            thinking_acc: [],
            thinking_blocks: [],
            current_block_type: nil,
            current_assistant_text_streamed?: false,
            stream_message_id: nil,
            tool_calls: %{},
            background_subagents: MapSet.new(),
            deferred_result: nil
        }
      else
        state
      end

    {active_messages ++ queued_messages, state}
  end

  defp release_session_home(state, session_id) do
    if state.managed? and Map.has_key?(state.session_homes, session_id) and
         not Map.has_key?(state.session_processes, session_id) do
      case RuntimeHome.release(runtime_home_release_opts(state, session_id), :claude) do
        :ok ->
          %{
            state
            | session_homes: Map.delete(state.session_homes, session_id),
              home_cleanup_errors: Map.delete(state.home_cleanup_errors, session_id)
          }
          |> refresh_cleanup_result()

        {:error, reason} ->
          %{
            state
            | home_cleanup_errors: Map.put(state.home_cleanup_errors, session_id, reason),
              cleanup_result: {:error, reason}
          }
      end
    else
      state
    end
  end

  defp refresh_cleanup_result(state) do
    child_error =
      Enum.find_value(state.session_processes, fn {_id, entry} ->
        Map.get(entry, :cleanup_error)
      end)

    home_error = Enum.find_value(state.home_cleanup_errors, fn {_id, reason} -> reason end)
    reason = child_error || home_error
    %{state | cleanup_result: if(reason, do: {:error, reason}, else: :ok)}
  end

  defp runtime_home_release_opts(state, session_id) do
    state.opts
    |> Keyword.put(
      :session_id,
      session_id || state.session_id || Keyword.get(state.opts, :session_id)
    )
    |> Keyword.merge(session_home_opts(state, session_id))
  end

  defp cancel_active_prompt(%{pending_prompt_id: nil} = state, _session_id), do: {[], state}

  defp cancel_active_prompt(%{active_prompt_session_id: session_id} = state, session_id) do
    messages = [Envelope.response(state.pending_prompt_id, %{"stopReason" => "cancelled"})]

    state =
      %{
        state
        | pending_prompt_id: nil,
          active_prompt_session_id: nil,
          text_acc: [],
          thinking_acc: [],
          thinking_blocks: [],
          current_block_type: nil,
          current_assistant_text_streamed?: false,
          stream_message_id: nil,
          tool_calls: %{},
          background_subagents: MapSet.new(),
          deferred_result: nil
      }

    {messages, state}
  end

  defp cancel_active_prompt(state, _session_id), do: {[], state}

  defp encode_permission_mode(:default), do: "default"
  defp encode_permission_mode(:accept_edits), do: "acceptEdits"
  defp encode_permission_mode(:plan), do: "plan"
  defp encode_permission_mode(:auto), do: "auto"
  defp encode_permission_mode(:dont_ask), do: "dontAsk"
  defp encode_permission_mode(:bypass), do: "bypassPermissions"
  defp encode_permission_mode(:bypass_permissions), do: "bypassPermissions"
  defp encode_permission_mode(mode) when is_binary(mode), do: mode
  defp encode_permission_mode(nil), do: "default"

  defp maybe_add_terminal_auth_methods(methods, opts, state) do
    caps = state.client_capabilities || %{}

    if terminal_auth_supported?(caps) do
      methods ++ terminal_auth_methods(opts, meta_terminal_auth_supported?(caps))
    else
      methods
    end
  end

  defp maybe_add_gateway_auth_methods(methods, opts, state) do
    if Keyword.get(opts, :gateway_auth, false) and
         get_in(state.client_capabilities || %{}, ["auth", "_meta", "gateway"]) == true do
      methods ++
        [
          %{
            "id" => "gateway",
            "name" => "Custom model gateway",
            "description" => "Use a custom gateway to authenticate and access models",
            "_meta" => %{"gateway" => %{"protocol" => "anthropic"}}
          },
          %{
            "id" => "gateway-bedrock",
            "name" => "Custom model gateway",
            "description" => "Use a custom gateway to authenticate and access models",
            "_meta" => %{"gateway" => %{"protocol" => "bedrock"}}
          }
        ]
    else
      methods
    end
  end

  defp terminal_auth_supported?(caps) do
    get_in(caps, ["auth", "terminal"]) == true or meta_terminal_auth_supported?(caps)
  end

  defp meta_terminal_auth_supported?(caps), do: get_in(caps, ["_meta", "terminal-auth"]) == true

  defp terminal_auth_methods(opts, include_meta?) do
    cli_path = ClaudeProtocol.cli_path(opts)

    if remote_environment?() do
      [
        terminal_auth_method(
          "claude-login",
          "Log in with Claude",
          "Run `claude /login` in the terminal",
          cli_path,
          [],
          "Claude Login",
          include_meta?,
          opts
        )
      ]
    else
      [
        terminal_auth_method(
          "claude-ai-login",
          "Claude Subscription",
          "Use Claude subscription",
          cli_path,
          ["auth", "login", "--claudeai"],
          "Claude Login",
          include_meta?,
          opts
        ),
        terminal_auth_method(
          "console-login",
          "Anthropic Console",
          "Use Anthropic Console (API usage billing)",
          cli_path,
          ["auth", "login", "--console"],
          "Anthropic Console Login",
          include_meta?,
          opts
        )
      ]
    end
  end

  defp terminal_auth_method(id, name, description, command, args, label, include_meta?, opts) do
    env = terminal_home_env(opts)

    method = %{
      "id" => id,
      "name" => name,
      "description" => description,
      "type" => "terminal",
      "args" => args,
      "env" => env
    }

    if include_meta? do
      Map.put(method, "_meta", %{
        "terminal-auth" => %{
          "command" => command,
          "args" => args,
          "label" => label,
          "env" => env
        }
      })
    else
      method
    end
  end

  defp terminal_home_env(opts) do
    env = RuntimeHome.put(%{}, opts, :claude)

    if path = env["CLAUDE_CONFIG_DIR"],
      do: RuntimeHome.track_keychain(Keyword.put(opts, :claude_config_dir, path))

    case RuntimeHome.env_value(opts, "ANTHROPIC_CONFIG_DIR") do
      nil ->
        env

      profile ->
        cwd = Keyword.get(opts, :cwd) || Keyword.get(opts, :cd) || File.cwd!()
        Map.put(env, "ANTHROPIC_CONFIG_DIR", Path.expand(profile, Path.expand(cwd)))
    end
  end

  defp remote_environment? do
    Enum.any?(
      ~w(NO_BROWSER SSH_CONNECTION SSH_CLIENT SSH_TTY CLAUDE_CODE_REMOTE),
      &System.get_env/1
    )
  end

  defp resolve_fast_mode_enabled(%{"value" => value}) when is_boolean(value), do: {:ok, value}
  defp resolve_fast_mode_enabled(%{"value" => "on"}), do: {:ok, true}
  defp resolve_fast_mode_enabled(%{"value" => "off"}), do: {:ok, false}

  defp resolve_fast_mode_enabled(%{"value" => other}),
    do: {:error, "Invalid fast mode value: #{inspect(other)}"}

  defp to_sdk_effort_level("default"), do: nil
  defp to_sdk_effort_level(nil), do: nil
  defp to_sdk_effort_level(effort), do: effort
end
