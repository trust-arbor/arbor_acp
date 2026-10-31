defmodule Arbor.ACP.Test.CodexNative do
  @moduledoc false
  import ExUnit.Assertions
  alias Arbor.ACP.Client
  alias Arbor.ACP.Adapters.Codex.Native
  alias Arbor.RPC.Subprocess

  @version_file Path.expand("../../fixtures/acp/codex/cli_version.txt", __DIR__)
  @version @version_file |> File.read!() |> String.trim()
  @external_resource @version_file

  defmodule Events do
    @moduledoc false
    use GenServer

    def start(client, parent), do: GenServer.start(__MODULE__, {client, parent})
    def await(pid, predicate, timeout), do: GenServer.call(pid, {:await, predicate}, timeout)

    @impl true
    def init({client, parent}) do
      Process.monitor(client)
      Process.monitor(parent)
      {:ok, %{events: [], count: 0, bytes: 0, waiter: nil}}
    end

    @impl true
    def handle_call({:await, predicate}, from, state) do
      case Enum.find(Enum.reverse(state.events), predicate) do
        nil -> {:noreply, %{state | waiter: {from, predicate}}}
        event -> {:reply, {:ok, event, Enum.reverse(state.events)}, state}
      end
    end

    @impl true
    def handle_info({:acp_extension_notification, "_arbor/codex/event", frame}, state) do
      event = frame["event"]

      state = %{
        state
        | events: [event | state.events],
          count: state.count + 1,
          bytes: state.bytes + :erlang.external_size(event)
      }

      cond do
        state.count > 2_000 or state.bytes > 4 * 1024 * 1024 ->
          if state.waiter, do: GenServer.reply(elem(state.waiter, 0), {:error, :event_bound})
          {:stop, :normal, state}

        state.waiter && elem(state.waiter, 1).(event) ->
          GenServer.reply(elem(state.waiter, 0), {:ok, event, Enum.reverse(state.events)})
          {:noreply, %{state | waiter: nil}}

        true ->
          {:noreply, state}
      end
    end

    def handle_info({:DOWN, _, :process, _, _}, state), do: {:stop, :normal, state}
  end

  defmodule Handler do
    @behaviour Arbor.ACP.Client.Handler
    def init(opts), do: {:ok, Map.new(opts)}

    def handle_session_update(_, update, state) do
      send(state.parent, {:qualification_acp_update, update})
      {:ok, state}
    end

    def handle_permission_request(_, _, _, state),
      do: {:ok, %{"outcome" => "cancelled"}, state}

    def handle_extension_request(
          "_arbor/codex/request",
          %{"method" => "item/tool/call", "params" => params},
          state
        ) do
      case {params["tool"], params["arguments"]} do
        {"qualification_echo", %{"value" => "native-input"}} ->
          send(state.parent, {:qualification_tool, params["callId"]})

          {:ok,
           %{
             "success" => true,
             "contentItems" => [%{"type" => "inputText", "text" => state.proof}]
           }, state}

        {"qualification_hold", _} ->
          send(state.parent, {:qualification_held, self()})

          receive do
            :release_qualification -> :ok
          after
            30_000 -> :ok
          end

          {:ok, %{"success" => false, "contentItems" => []}, state}

        _ ->
          {:error, %{"code" => -32602, "message" => "Unexpected qualification tool arguments"},
           state}
      end
    end

    def handle_extension_request(
          "_arbor/codex/request",
          %{"method" => method, "params" => params},
          state
        )
        when method in [
               "item/commandExecution/requestApproval",
               "item/fileChange/requestApproval"
             ] do
      send(state.parent, {:qualification_approval, method, params["itemId"]})
      {:ok, %{"decision" => "decline"}, state}
    end

    def handle_extension_request(_, _, state),
      do: {:error, %{"code" => -32601, "message" => "Unsupported qualification request"}, state}
  end

  def with_client(name, opts \\ [], fun) do
    authenticated? = Keyword.get(opts, :authenticated, false)

    if authenticated?,
      do:
        assert(
          System.get_env("ARBOR_CODEX_AUTH_QUALIFICATION") == "1",
          "Authenticated qualification requires explicit opt-in"
        )

    executable = System.get_env("CODEX_PATH") || System.find_executable("codex")
    assert is_binary(executable), "Pinned Codex executable is required; set CODEX_PATH"
    {:ok, version, 0} = Subprocess.capture([executable, "--version"], timeout: 10_000)

    assert Regex.match?(~r/codex-cli #{@version |> Regex.escape()}(?:\s|$)/, version),
           "Codex CLI must match the reviewed #{@version} pin"

    nonce = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    root = Path.join(System.tmp_dir!(), "arbor-codex-native-#{nonce}")

    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, "codex-state"))
    proof = "native-proof-#{System.unique_integer([:positive])}"
    # Authenticated qualification explicitly selects the caller-owned login home.
    # Private generated homes intentionally cannot see that login by default.
    home =
      if authenticated? do
        case System.get_env("CODEX_HOME") do
          value when value in [nil, ""] -> Path.join(System.user_home!(), ".codex")
          value -> Path.expand(value)
        end
      else
        Path.join(root, "codex-state")
      end

    env = [{"CODEX_HOME", home}]
    launch = if authenticated?, do: isolated_launcher(root, executable), else: executable

    {:ok, client} =
      Native.start_link(
        native_mode: Keyword.get(opts, :native_mode, :exclusive),
        handler: Handler,
        handler_opts: [parent: self(), proof: proof],
        initialize_timeout: 30_000,
        pending_request_timeout: 30_000,
        handler_request_timeout: 45_000,
        adapter_opts: [
          codex_path: launch,
          cwd: root,
          workspace_roots: [root],
          process_group: true,
          env: env,
          native_initialize_params: %{"capabilities" => %{"experimentalApi" => true}}
        ]
      )

    Process.unlink(client)
    bridge = :sys.get_state(client).transport_state.bridge
    child = :sys.get_state(bridge).port
    assert match?(%Subprocess{}, child)
    monitor = Process.monitor(client)

    outcome =
      try do
        if authenticated? do
          account = request!(client, "account/read", %{"refreshToken" => false})
          assert not is_nil(account["account"]), "Codex account is not authenticated"
        end

        {:ok, fun.(%{client: client, root: root, proof: proof})}
      rescue
        error -> {:error, error, __STACKTRACE__}
      after
        assert :ok == Client.stop(client), "Native client cleanup failed"
        assert_receive {:DOWN, ^monitor, :process, ^client, _}, 2_000
      end

    assert {:ok, %{direct_child: :reaped, targeted_group: :absent}} =
             Subprocess.cleanup_receipt(child)

    File.rm_rf!(root)

    case outcome do
      {:ok, details} ->
        record(
          name,
          Map.merge(
            %{
              status: "passed",
              cli_version: @version,
              elixir: System.version(),
              otp: to_string(:erlang.system_info(:otp_release)),
              cleanup_verified: true,
              requested_model: System.get_env("ARBOR_CODEX_QUALIFICATION_MODEL")
            },
            details || %{}
          )
        )

      {:error, error, stack} ->
        record(name, %{
          status: "failed",
          failure_class: inspect(error.__struct__),
          cli_version: @version,
          cleanup_verified: true
        })

        reraise error, stack
    end
  end

  defp isolated_launcher(root, executable) do
    path = Path.join(root, "codex-qualification")
    quoted = "'" <> String.replace(executable, "'", "'\\''") <> "'"

    File.write!(
      path,
      "#!/bin/sh\nexec #{quoted} \"$@\" -c 'mcp_servers={}' -c 'features.apps=false' -c 'features.plugins=false' -c 'features.hooks=false' -c 'web_search=\"disabled\"'\n"
    )

    File.chmod!(path, 0o700)
    path
  end

  def request!(client, method, params \\ %{}) do
    case Native.request(client, method, params, timeout: 35_000) do
      {:ok, result} -> result
      {:error, %{"code" => code}} -> flunk("Native #{method} failed with code #{code}")
      {:error, reason} when is_atom(reason) -> flunk("Native #{method} failed: #{reason}")
      _ -> flunk("Native #{method} failed")
    end
  end

  # An explicit, available model makes live qualification reproducible without
  # changing the user's global CLI configuration or the adapter's defaults.
  def qualification_model_params do
    case System.get_env("ARBOR_CODEX_QUALIFICATION_MODEL") do
      value when value in [nil, ""] -> %{}
      value -> %{"model" => value}
    end
  end

  def start_thread!(client, root, extra \\ %{}) do
    request!(
      client,
      "thread/start",
      Map.merge(
        %{
          "cwd" => root,
          "approvalPolicy" => "on-request",
          "approvalsReviewer" => "user",
          "sandbox" => "read-only",
          "ephemeral" => true,
          "baseInstructions" =>
            "You are a protocol qualification agent. Follow the user's exact test. Use tools only when explicitly requested. Do not inspect unrelated files or access the network."
        },
        Map.merge(qualification_model_params(), extra)
      )
    )
  end

  def turn!(client, thread, prompt, extra \\ %{}) do
    request!(
      client,
      "turn/start",
      Map.merge(
        %{"threadId" => thread, "input" => [%{"type" => "text", "text" => prompt}]},
        extra
      )
    )
  end

  def subscribe!(client) do
    {:ok, consumer} = Events.start(client, self())
    assert :ok == Native.subscribe(client, consumer), "Native event subscription failed"
    consumer
  end

  def await_turn(consumer, thread, turn \\ nil, timeout \\ 120_000) do
    {event, events} =
      await_event(
        consumer,
        fn event ->
          event["method"] == "turn/completed" and get_in(event, ["params", "threadId"]) == thread and
            (is_nil(turn) or get_in(event, ["params", "turn", "id"]) == turn)
        end,
        timeout
      )

    %{turn: event["params"]["turn"], events: events}
  end

  def await_method(consumer, method, timeout \\ 5_000),
    do: await_event(consumer, &(&1["method"] == method), timeout)

  defp await_event(consumer, predicate, timeout) do
    case Events.await(consumer, predicate, timeout) do
      {:ok, event, events} -> {event, events}
      {:error, :event_bound} -> flunk("Native qualification event bound exceeded")
    end
  catch
    :exit, _ -> flunk("Native event unavailable within its qualification deadline")
  end

  def assert_completed!(result),
    do:
      assert(
        result.turn["status"] == "completed",
        "Native turn failed: #{get_in(result.turn, ["error", "codexErrorInfo"]) |> error_class()}"
      )

  defp error_class(value) when is_binary(value), do: value
  defp error_class(value) when is_map(value), do: value |> Map.keys() |> Enum.join(",")
  defp error_class(_), do: "unspecified"

  def text(result) do
    for %{"method" => "item/agentMessage/delta", "params" => %{"delta" => delta}} <-
          result.events,
        into: "",
        do: delta
  end

  def dynamic_tool(name, schema),
    do: %{
      "type" => "function",
      "name" => name,
      "description" => "Protocol qualification only. Returns a test value; no external effects.",
      "inputSchema" => schema
    }

  defp record(name, details) do
    if path = System.get_env("ARBOR_CODEX_QUALIFICATION_REPORT") do
      identity = %{
        packages:
          Map.new([:arbor_acp, :arbor_acp_adapters, :arbor_rpc], fn app ->
            {app, app |> Application.spec(:vsn) |> to_string()}
          end),
        beam_sha256:
          Map.new(
            [
              Client,
              Native,
              Arbor.ACP.Adapters.Codex,
              Arbor.ACP.Adapters.Codex.NativeProtocol,
              Arbor.ACP.AdapterBridge,
              Subprocess
            ],
            fn module ->
              {:module, ^module} = Code.ensure_loaded(module)
              {^module, bytecode, _} = :code.get_object_code(module)
              {inspect(module), :crypto.hash(:sha256, bytecode) |> Base.encode16(case: :lower)}
            end
          )
      }

      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(Map.merge(identity, Map.put(details, :case, name))) <> "\n",
        [:append]
      )
    end
  end
end
