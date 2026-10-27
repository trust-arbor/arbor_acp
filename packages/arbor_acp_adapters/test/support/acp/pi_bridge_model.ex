defmodule Arbor.ACP.Test.PiBridgeModel do
  @moduledoc """
  Model-based checking of the Pi adapter through `Arbor.ACP.AdapterBridge`.

  `commands/0` generates interleavings of ACP requests and fake Pi events, and
  `run/3` executes one against a real bridge and a scripted fake Pi, in
  managed mode (the adapter owns a Pi process per session) or unmanaged mode
  (the bridge owns one long-lived Pi process, the way a callback consumer
  owns its transport; see `UnmanagedPi`).

  ## Commands

  ACP requests: `:new`, `{:load, n}`, `{:resume, n}` (the `n`th known
  session, or an unknown id), `{:prompt, kind}` (a text prompt, a slash
  command answered by Pi, a slash command Pi runs as a turn, or one the
  adapter answers itself), `{:set_model, id}`, `:cancel` (`session/cancel`),
  `{:cancel_request, n}` (`$/cancel_request` for the `n`th unanswered
  request), `{:close, target}` and `{:delete, target}` (the current session
  or another one).

  Fake Pi events: `{:reply, n, outcome}` (answer the `n`th unanswered Pi
  request with success, failure, or `cancelled: true` for a session change,
  so replies arrive in any order), `:delta`, `:agent_end` and
  `:agent_settled` (the running turn's events), `:thinking_changed`, `:exit`
  (Pi exits) and `:break` (Pi's stdin breaks, so the adapter's writes fail
  until Pi exits).

  Commands that do not apply (a reply with nothing to answer, a prompt with
  no current session) are skipped, so every generated list is valid.

  ## Fake Pi

  `bin/pi` logs each stdin line to `log/<os pid>.log` and prints the payload
  of `__emit__ <line>` on stdout; `__exit__ N` exits, and `__hold__` keeps
  it alive after its stdin closes. The harness learns what the adapter
  wrote by appending a `__sync__ K` marker through the same handle and
  reading the log up to it; it injects Pi output with `__emit__` lines
  followed by a barrier event (`session_info_changed` named
  `__barrier_K__`) and reads the bridge until the barrier's update arrives.
  The Pi model answers like Pi does: a successful session change first
  settles a running turn, a prompt that arrives during a turn is rejected,
  `abort` only marks the turn aborted (its `agent_end` and `agent_settled`
  still come), and `get_state` reports the session Pi is on.

  ## Invariants

  Checked after every step:

    * every ACP request is answered at most once, and only requests that
      were sent are answered;
    * a prompt's `end_turn` comes only from its own Pi turn settling, carries
      its own session id, and its text and streamed chunks hold only that
      turn's deltas;
    * no `session/update` names a session other than the client's current
      one (or a session a pending load replays);
    * a successful setup names the session Pi is on, and an idle adapter
      serves the client's current session and the session Pi is on;
    * the bridge never crashes.

  After the commands, the harness answers every Pi request and settles every
  turn until nothing changes, then checks that every request was answered
  exactly once and that the adapter's queues and pending maps are empty.
  When unmanaged Pi exits, the bridge closes and the client fails what is
  outstanding, so only the at-most-once checks apply.
  """

  import ExUnit.Assertions

  alias Arbor.ACP.AdapterBridge
  alias Arbor.ACP.Adapters.Internal.PromptQueue
  alias Arbor.ACP.Adapters.Pi
  alias Arbor.ACP.AdapterSupport.Subprocess, as: PortRunner
  alias Arbor.ACP.TestHelpers
  alias Arbor.RPC.Subprocess

  defmodule UnmanagedPi do
    @moduledoc """
    The Pi adapter in unmanaged mode with a bridge-owned Pi process.

    An unmanaged consumer owns Pi's transport and writes what the adapter
    returns; here the bridge plays that consumer: `command/1` names the
    fake Pi, so the bridge opens it, writes every returned payload to it and
    feeds its output to `translate_inbound/2`.
    """
    @behaviour Arbor.ACP.Adapter

    alias Arbor.ACP.Adapters.Pi

    @impl true
    def init(opts), do: Pi.init(Keyword.put(opts, :managed, false))

    @impl true
    def command(opts), do: {Keyword.fetch!(opts, :cli_path), ["--mode", "rpc", "--no-themes"]}

    @impl true
    defdelegate name(), to: Pi
    @impl true
    defdelegate capabilities(), to: Pi
    @impl true
    defdelegate auth_methods(opts), to: Pi
    @impl true
    defdelegate modes(), to: Pi
    @impl true
    defdelegate config_options(), to: Pi
    @impl true
    defdelegate list_sessions(params, state), to: Pi
    @impl true
    defdelegate translate_outbound(message, state), to: Pi
    @impl true
    defdelegate translate_inbound(line, state), to: Pi
    @impl true
    defdelegate outbound_write_failed(message, reason, state), to: Pi
    @impl true
    defdelegate shutdown(state), to: Pi
    @impl true
    defdelegate environment_defaults(opts), to: Pi
  end

  @models [
    %{"provider" => "fake", "id" => "m1", "name" => "Model One"},
    %{"provider" => "fake", "id" => "m2", "name" => "Model Two"}
  ]
  @levels ~w(off low medium high)
  @seeded_sessions ["S1", "S2"]
  @timeout 5_000
  @drain_limit 400

  @fake_pi """
  #!/bin/sh
  log="__LOG_DIR__/$$.log"
  printf 'argv %s\\n' "$*" >> "$log"
  hold=0
  while IFS= read -r line; do
    case "$line" in
      "__emit__ "*) printf '%s\\n' "${line#__emit__ }" ;;
      "__exit__ "*) exit "${line#__exit__ }" ;;
      "__hold__") hold=1 ;;
      "__sync__ "*)
        printf '%s\\n' "$line" >> "$log"
        printf '{"type":"session_info_changed","name":"__barrier_sync_%s__"}\\n' "${line#__sync__ }" ;;
      *) printf '%s\\n' "$line" >> "$log" ;;
    esac
  done
  if [ "$hold" = 1 ]; then while :; do sleep 1; done; fi
  """

  # -- generators -------------------------------------------------------------

  @doc """
  A StreamData generator of command lists (see the module doc). Most lists
  start by opening a session, so prompts and session changes meet each other.
  """
  def commands(max_length \\ 30) do
    import StreamData

    map(
      tuple(
        {frequency([{5, constant(true)}, {1, constant(false)}]),
         list_of(command(), max_length: max_length)}
      ),
      fn
        {true, commands} -> [:open | commands]
        {false, commands} -> commands
      end
    )
  end

  defp command do
    import StreamData

    frequency([
      {3, constant(:new)},
      {2, tuple({constant(:load), integer(0..4)})},
      {1, tuple({constant(:resume), integer(0..4)})},
      {6,
       tuple(
         {constant(:prompt),
          frequency([
            {5, constant(:text)},
            {1, constant(:slash_session)},
            {1, constant(:slash_compact)},
            {1, constant(:slash_forward)},
            {1, constant(:slash_notice)}
          ])}
       )},
      {2, tuple({constant(:set_model), member_of(["fake/m1", "fake/m2"])})},
      {2, constant(:cancel)},
      {2, tuple({constant(:cancel_request), integer(0..6)})},
      {1, tuple({constant(:close), member_of([:current, :other])})},
      {1, tuple({constant(:delete), member_of([:current, :other])})},
      {3, constant(:reply_all)},
      {14,
       tuple(
         {constant(:reply), integer(0..6),
          frequency([{8, constant(:ok)}, {1, constant(:fail)}, {1, constant(:cancelled)}])}
       )},
      {2, constant(:delta)},
      {3, constant(:agent_end)},
      {3, constant(:agent_settled)},
      {1, constant(:thinking_changed)},
      {1, constant(:exit)},
      {1, constant(:break)}
    ])
  end

  # -- running ----------------------------------------------------------------

  @doc """
  Runs `commands` in `mode` (`:managed` or `:unmanaged`) and checks the
  invariants; raises an `ExUnit.AssertionError` naming the step on a
  violation.
  """
  def run(mode, commands) when mode in [:managed, :unmanaged] and is_list(commands) do
    Process.flag(:trap_exit, true)
    world = start(mode)

    try do
      world
      |> request("initialize", %{"protocolVersion" => 1}, %{kind: :other})
      |> after_step(:initialize)
      |> then(fn world -> Enum.reduce(commands, world, &step/2) end)
      |> drain(0)
      |> final_checks()
    after
      stop(world)
    end
  end

  defp step(command, world) do
    trace("step #{inspect(command)}")
    world = %{world | trace: [command | world.trace], settled: MapSet.new()}

    command
    |> exec(world)
    |> after_step(command)
  end

  defp start(mode) do
    sandbox = Path.join(System.tmp_dir!(), "pi_model_#{System.unique_integer([:positive])}")

    for dir <- ["bin", "log", "agent", "sessions", "project"],
        do: File.mkdir_p!(Path.join(sandbox, dir))

    File.write!(Path.join(sandbox, "agent/settings.json"), ~s({"quietStartup": true}))
    pi = Path.join(sandbox, "bin/pi")
    File.write!(pi, String.replace(@fake_pi, "__LOG_DIR__", Path.join(sandbox, "log")))
    File.chmod!(pi, 0o755)

    sessions =
      Map.new(@seeded_sessions, fn id ->
        file = session_file(sandbox, id)
        File.write!(file, Jason.encode!(%{"type" => "session", "id" => id}) <> "\n")

        {id, %{"sessionId" => id, "cwd" => Path.join(sandbox, "project"), "sessionFile" => file}}
      end)

    File.write!(
      Path.join(sandbox, "session-map.json"),
      Jason.encode!(%{"version" => 1, "sessions" => sessions})
    )

    opts = [
      cwd: Path.join(sandbox, "project"),
      agent_dir: Path.join(sandbox, "agent"),
      session_dir: Path.join(sandbox, "sessions"),
      session_map_path: Path.join(sandbox, "session-map.json"),
      cli_path: pi,
      update_notice: false,
      managed: mode == :managed,
      eof_grace: 20
    ]

    adapter = if mode == :managed, do: Pi, else: UnmanagedPi
    {:ok, bridge} = AdapterBridge.start_link(adapter: adapter, adapter_opts: opts)

    %{
      mode: mode,
      sandbox: sandbox,
      bridge: bridge,
      trace: [],
      closed?: false,
      next_id: 0,
      requests: %{},
      current: nil,
      known: @seeded_sessions,
      settled: MapSet.new(),
      barrier: 0,
      created: 0,
      boots: 0,
      pi: dead_pi()
    }
    |> detect_process()
  end

  defp stop(world) do
    if Process.alive?(world.bridge) do
      try do
        AdapterBridge.close(world.bridge)
      catch
        :exit, _reason -> :ok
      end
    end

    File.rm_rf(world.sandbox)
  end

  defp dead_pi,
    do: %{
      handle: nil,
      generation: nil,
      log: nil,
      offset: 0,
      sync: 0,
      session: nil,
      pending: [],
      turn: nil,
      broken?: false
    }

  defp session_file(sandbox, id), do: Path.join([sandbox, "sessions", id <> ".jsonl"])

  # -- ACP commands -------------------------------------------------------------

  defp exec(_command, %{closed?: true} = world), do: world

  # Opens a session: session/new, with every Pi request answered until the
  # setup is answered.
  defp exec(:open, world) do
    world = exec(:new, world)
    open_until_answered(world, world.next_id - 1, 0)
  end

  defp exec(:new, world) do
    request(world, "session/new", %{"cwd" => cwd(world)}, %{kind: :setup, target: :new})
  end

  defp exec({kind, n}, world) when kind in [:load, :resume] do
    known = world.known
    index = rem(n, length(known) + 1)
    target = if index < length(known), do: Enum.at(known, index), else: "gone"

    request(
      world,
      "session/#{kind}",
      %{"sessionId" => target, "cwd" => cwd(world)},
      %{kind: :setup, target: target}
    )
  end

  defp exec({:prompt, _kind}, %{current: nil} = world), do: world

  defp exec({:prompt, kind}, world) do
    id = world.next_id

    {text, turn?} =
      case kind do
        :text -> {"prompt ##{id}", true}
        :slash_forward -> {"/unknowncmd ##{id}", true}
        :slash_session -> {"/session", false}
        :slash_compact -> {"/compact", false}
        :slash_notice -> {"/model", false}
      end

    request(
      world,
      "session/prompt",
      %{"sessionId" => world.current, "prompt" => [%{"type" => "text", "text" => text}]},
      %{kind: :prompt, turn?: turn?, session: world.current}
    )
  end

  defp exec({:set_model, _model}, %{current: nil} = world), do: world

  defp exec({:set_model, model}, world) do
    request(
      world,
      "session/set_model",
      %{"sessionId" => world.current, "modelId" => model},
      %{kind: :other}
    )
  end

  defp exec(:cancel, %{current: nil} = world), do: world

  defp exec(:cancel, world),
    do: notify(world, "session/cancel", %{"sessionId" => world.current})

  defp exec({:cancel_request, n}, world) do
    case unanswered(world) do
      [] ->
        world

      ids ->
        notify(world, "$/cancel_request", %{"requestId" => Enum.at(ids, rem(n, length(ids)))})
    end
  end

  defp exec({kind, target}, world) when kind in [:close, :delete] do
    session = if target == :current, do: world.current || "none", else: "elsewhere"
    world = if session == world.current, do: %{world | current: nil}, else: world
    request(world, "session/#{kind}", %{"sessionId" => session}, %{kind: :other})
  end

  # -- Pi commands ----------------------------------------------------------------

  defp exec(_command, %{pi: %{handle: nil}} = world), do: world

  defp exec(:exit, world), do: pi_exit(world)
  defp exec(_command, %{pi: %{broken?: true}} = world), do: world

  defp exec(:reply_all, world), do: reply_all(world)

  defp exec({:reply, n, outcome}, world) do
    case world.pi.pending do
      [] ->
        world

      pending ->
        request = Enum.at(pending, rem(n, length(pending)))
        world = update_in(world.pi.pending, &List.delete(&1, request))
        {lines, world} = reply_lines(request, outcome, world)
        emit(world, lines)
    end
  end

  defp exec(:delta, %{pi: %{turn: %{ended?: false} = turn}} = world),
    do:
      emit(world, [event(%{"type" => "message_update", "assistantMessageEvent" => delta(turn)})])

  defp exec(:agent_end, %{pi: %{turn: %{ended?: false}}} = world) do
    world = put_in(world.pi.turn.ended?, true)
    emit(world, [agent_end()])
  end

  defp exec(:agent_settled, %{pi: %{turn: %{ended?: true} = turn}} = world) do
    world = %{world | settled: MapSet.put(world.settled, turn.tag)}
    world = put_in(world.pi.turn, nil)
    emit(world, [event(%{"type" => "agent_settled", "aborted" => turn.aborted?})])
  end

  defp exec(:thinking_changed, world),
    do: emit(world, [event(%{"type" => "thinking_level_changed", "level" => "high"})])

  defp exec(:break, world) do
    world = sync(world)
    _ = PortRunner.command(world.pi.handle, "__hold__\n")
    _ = Subprocess.close_input(world.pi.handle)
    put_in(world.pi.broken?, true)
  end

  defp exec(_command, world), do: world

  defp cwd(world), do: Path.join(world.sandbox, "project")

  defp open_until_answered(world, id, round) do
    world = world |> detect_process() |> sync() |> drain_outbox()

    if world.requests[id].answers > 0 or world.pi.pending == [] or round > 20,
      do: world,
      else: world |> reply_all() |> open_until_answered(id, round + 1)
  end

  defp reply_all(%{pi: %{pending: []}} = world), do: world
  defp reply_all(%{pi: %{handle: nil}} = world), do: world
  defp reply_all(%{pi: %{broken?: true}} = world), do: world

  defp reply_all(world) do
    {pending, world} = {world.pi.pending, put_in(world.pi.pending, [])}

    {lines, world} =
      Enum.reduce(pending, {[], world}, fn request, {lines, world} ->
        {more, world} = reply_lines(request, :ok, world)
        {lines ++ more, world}
      end)

    emit(world, lines)
  end

  defp unanswered(world), do: for({id, %{answers: 0}} <- world.requests, do: id)

  defp request(world, method, params, meta) do
    id = world.next_id
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    entry = Map.merge(%{method: method, params: params, answers: 0}, meta)
    world = %{world | next_id: id + 1, requests: Map.put(world.requests, id, entry)}
    send_to_bridge(world, message)
  end

  defp notify(world, method, params) do
    send_to_bridge(world, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  defp send_to_bridge(world, message) do
    result =
      try do
        AdapterBridge.send_message(world.bridge, Jason.encode!(message))
      catch
        :exit, reason ->
          flunk(violation(world, "the bridge crashed on #{inspect(message)}: #{inspect(reason)}"))
      end

    case result do
      :ok ->
        world

      {:error, :closed} ->
        assert world.mode == :unmanaged, violation(world, "the managed bridge closed")
        %{world | closed?: true}

      {:error, reason} ->
        # A notification the adapter could not honour has no response.
        refute Map.has_key?(message, "id"),
               violation(world, "send_message failed for a request: #{inspect(reason)}")

        world
    end
  end

  # -- fake Pi ----------------------------------------------------------------------

  defp reply_lines(%{"type" => type} = request, outcome, world)
       when type in ["new_session", "switch_session"] do
    case outcome do
      :fail ->
        {[failure(request, "fake #{type} failure")], world}

      :cancelled ->
        {[success(request, %{"cancelled" => true})], world}

      :ok ->
        # Pi settles a running turn before it replaces the session.
        {settle, world} = settle_for_change(world)

        {session, world} =
          if type == "new_session" do
            created = world.created + 1
            id = "N#{created}"
            {%{id: id, file: session_file(world.sandbox, id)}, %{world | created: created}}
          else
            file = request["sessionPath"]
            {%{id: Path.basename(file, ".jsonl"), file: file}, world}
          end

        world = put_in(world.pi.session, session)
        {settle ++ [success(request, %{"cancelled" => false})], world}
    end
  end

  defp reply_lines(%{"type" => "prompt"} = request, outcome, world) do
    cond do
      request[:rejected?] ->
        {[failure(request, "Agent is already processing")], world}

      outcome == :ok ->
        tag = prompt_tag(request["message"])
        world = put_in(world.pi.turn, %{tag: tag, aborted?: false, ended?: false})
        {[success(request, %{"disposition" => "immediate"})], world}

      true ->
        {[failure(request, "fake prompt failure")], world}
    end
  end

  defp reply_lines(request, :ok, world),
    do: {[success(request, reply_data(request, world))], world}

  defp reply_lines(request, _outcome, world), do: {[failure(request, "fake failure")], world}

  defp reply_data(%{"type" => "get_state"}, world) do
    %{
      "sessionId" => world.pi.session.id,
      "sessionFile" => world.pi.session.file,
      "thinkingLevel" => "medium",
      "model" => %{"provider" => "fake", "id" => "m1"},
      "isStreaming" => world.pi.turn != nil
    }
  end

  defp reply_data(%{"type" => "get_available_models"}, _world), do: %{"models" => @models}

  defp reply_data(%{"type" => "get_available_thinking_levels"}, _world),
    do: %{"levels" => @levels}

  defp reply_data(%{"type" => "get_commands"}, _world), do: %{"commands" => []}
  defp reply_data(%{"type" => "get_messages"}, _world), do: %{"messages" => []}
  defp reply_data(%{"type" => "compact"}, _world), do: %{"summary" => "s", "tokensBefore" => 10}

  defp reply_data(%{"type" => "get_session_stats"}, world) do
    %{
      "sessionId" => world.pi.session.id,
      "sessionFile" => world.pi.session.file,
      "totalMessages" => 2,
      "contextUsage" => %{"tokens" => 10, "contextWindow" => 1000}
    }
  end

  defp reply_data(_request, _world), do: %{}

  defp settle_for_change(%{pi: %{turn: nil}} = world), do: {[], world}

  defp settle_for_change(%{pi: %{turn: turn}} = world) do
    world = %{world | settled: MapSet.put(world.settled, turn.tag)}
    world = put_in(world.pi.turn, nil)

    end_line = if turn.ended?, do: [], else: [agent_end()]
    {end_line ++ [event(%{"type" => "agent_settled", "aborted" => true})], world}
  end

  defp success(request, data),
    do:
      event(%{
        "type" => "response",
        "id" => request["id"],
        "command" => request["type"],
        "success" => true,
        "data" => data
      })

  defp failure(request, error),
    do:
      event(%{
        "type" => "response",
        "id" => request["id"],
        "command" => request["type"],
        "success" => false,
        "error" => error
      })

  defp agent_end,
    do:
      event(%{
        "type" => "agent_end",
        "messages" => [
          %{"role" => "assistant", "usage" => %{"input" => 3, "output" => 2, "totalTokens" => 5}}
        ]
      })

  defp delta(turn), do: %{"type" => "text_delta", "delta" => "[##{turn.tag}]"}
  defp event(map), do: Jason.encode!(map)

  defp prompt_tag(message) do
    case Regex.run(~r/#(\d+)/, to_string(message)) do
      [_, tag] -> String.to_integer(tag)
      _ -> nil
    end
  end

  # Writes the lines to Pi's stdout and reads the bridge until the barrier.
  defp emit(world, lines) do
    barrier = world.barrier + 1
    world = %{world | barrier: barrier}
    name = "__barrier_#{barrier}__"
    marker = event(%{"type" => "session_info_changed", "name" => name})
    Enum.each(lines, &trace("pi -> #{&1}"))
    data = Enum.map(lines ++ [marker], &["__emit__ ", &1, "\n"])

    case PortRunner.command(world.pi.handle, data) do
      :ok -> await_barrier(world, name, System.monotonic_time(:millisecond) + @timeout)
      {:error, _reason} -> world
    end
  end

  defp await_barrier(world, name, deadline) do
    case receive_from_bridge(world, 50) do
      {:ok, json} ->
        message = Jason.decode!(json)

        if barrier_name(message) == name,
          do: world,
          else: await_barrier(observe(world, traced(message)), name, deadline)

      {:error, :closed} ->
        world

      {:error, :timeout} ->
        cond do
          current_generation(world) != world.pi.generation ->
            world

          System.monotonic_time(:millisecond) > deadline ->
            flunk(violation(world, "the bridge never processed Pi's output"))

          true ->
            await_barrier(world, name, deadline)
        end
    end
  end

  # The bridge may be busy longer than a short receive's call timeout (it
  # starts and stops Pi processes inline).
  defp receive_from_bridge(world, timeout) do
    AdapterBridge.receive_message(world.bridge, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
  end

  defp barrier_name(%{"params" => %{"update" => %{"title" => "__barrier_" <> _ = title}}}),
    do: title

  defp barrier_name(_message), do: nil

  defp pi_exit(world) do
    generation = world.pi.generation

    if world.pi.broken? do
      {_out, _status} = System.cmd("kill", ["-9", to_string(Subprocess.os_pid(world.pi.handle))])
    else
      _ = PortRunner.command(world.pi.handle, "__exit__ 1\n")
    end

    TestHelpers.wait_until(
      fn -> bridge_closed?(world) or current_generation(world) != generation end,
      timeout: @timeout,
      interval: 2
    )

    world
  end

  # Collects what the adapter wrote to Pi since the last sync.
  defp sync(%{pi: %{handle: nil}} = world), do: world
  defp sync(%{pi: %{broken?: true}} = world), do: world

  defp sync(world) do
    k = world.pi.sync + 1
    marker = "__sync__ #{k}\n"
    world = put_in(world.pi.sync, k)

    case PortRunner.command(world.pi.handle, marker) do
      :ok ->
        # Pi logs the marker, then prints a barrier: once the bridge has
        # processed the barrier, the log holds every line written before it.
        deadline = System.monotonic_time(:millisecond) + @timeout
        world = await_barrier(world, "__barrier_sync_#{k}__", deadline)
        content = read_log(world)
        rest = binary_part(content, world.pi.offset, byte_size(content) - world.pi.offset)

        case String.split(rest, marker, parts: 2) do
          [chunk, _after] ->
            world =
              put_in(world.pi.offset, world.pi.offset + byte_size(chunk) + byte_size(marker))

            chunk
            |> String.split("\n", trim: true)
            |> Enum.reduce(world, &receive_line/2)

          [_no_marker] ->
            world
        end

      {:error, _reason} ->
        world
    end
  end

  defp read_log(world) do
    case File.read(world.pi.log) do
      {:ok, content} -> content
      {:error, _reason} -> ""
    end
  end

  defp receive_line("argv " <> _argv = line, world) do
    trace("pi #{world.pi.log |> Path.basename()} #{line}")
    world
  end

  defp receive_line(line, world) do
    trace("pi #{world.pi.log |> Path.basename()} <- #{line}")

    case Jason.decode!(line) do
      %{"type" => "abort"} ->
        if world.pi.turn, do: put_in(world.pi.turn.aborted?, true), else: world

      %{"id" => _id, "type" => "prompt"} = request ->
        # Pi rejects a prompt that arrives while a turn runs.
        request = if world.pi.turn, do: Map.put(request, :rejected?, true), else: request
        update_in(world.pi.pending, &(&1 ++ [request]))

      %{"id" => _id} = request ->
        update_in(world.pi.pending, &(&1 ++ [request]))

      _notification ->
        world
    end
  end

  # -- after each step ------------------------------------------------------------

  defp after_step(world, command) do
    assert Process.alive?(world.bridge), violation(world, "the bridge crashed")

    receive do
      {:EXIT, pid, reason} when pid == world.bridge ->
        flunk(violation(world, "the bridge exited: #{inspect(reason)}"))
    after
      0 -> :ok
    end

    world =
      world
      |> detect_process()
      |> sync()
      |> drain_outbox()

    world
    |> check_session_agreement(command)
    |> check_tracking()
  end

  # A request the adapter answers later is tracked until it is answered, and
  # not after; every other request is answered within its own step.
  defp check_tracking(%{closed?: true} = world), do: world

  defp check_tracking(world) do
    tracked = tracked_requests(bridge_state(world).adapter_state)

    for {id, request} <- world.requests do
      case {request.kind, request.answers} do
        {kind, 0} when kind in [:setup, :prompt] ->
          assert MapSet.member?(tracked, id),
                 violation(world, "request #{id} (#{request.method}) was dropped unanswered")

        {kind, 1} when kind in [:setup, :prompt] ->
          refute MapSet.member?(tracked, id),
                 violation(
                   world,
                   "request #{id} (#{request.method}) is still tracked after its answer"
                 )

        {_other, answers} ->
          assert answers == 1,
                 violation(world, "request #{id} (#{request.method}) was not answered at once")
      end
    end

    world
  end

  defp tracked_requests(adapter) do
    prompt = if adapter.pending_prompt, do: [adapter.pending_prompt.acp_id], else: []
    queued = adapter.prompt_queue |> PromptQueue.to_list() |> Enum.map(& &1.acp_id)
    groups = adapter.control_groups |> Map.values() |> Enum.map(& &1.acp_id)

    running =
      case adapter.op_in_flight do
        %{type: :setup, cancelled?: true} -> []
        %{type: :setup, acp_id: acp_id} -> [acp_id]
        _op -> []
      end

    waiting = for %{type: :setup, plan: plan} <- adapter.op_queue, do: elem(plan, 1)
    MapSet.new(prompt ++ queued ++ groups ++ running ++ waiting)
  end

  defp detect_process(world) do
    generation = current_generation(world)

    cond do
      bridge_closed?(world) ->
        %{world | closed?: true, pi: dead_pi()}

      generation == world.pi.generation ->
        world

      generation == nil ->
        %{drain_outbox(world) | pi: dead_pi()}

      true ->
        # What the adapter emitted before it replaced Pi belongs to the old Pi.
        world = drain_outbox(world)
        handle = current_handle(world)
        os_pid = Subprocess.os_pid(handle)
        log = Path.join([world.sandbox, "log", "#{os_pid}.log"])
        pi = %{dead_pi() | handle: handle, generation: generation, log: log}
        world = sync(%{world | pi: pi})
        {session, world} = boot_session(world)
        put_in(world.pi.session, session)
    end
  end

  # Pi resumes `--session <file>`, or starts on a fresh session.
  defp boot_session(world) do
    case Regex.run(~r/^argv .*--session (\S+)/m, read_log(world)) do
      [_, file] ->
        {%{id: Path.basename(file, ".jsonl"), file: file}, world}

      nil ->
        boots = world.boots + 1
        id = "boot#{boots}"
        {%{id: id, file: session_file(world.sandbox, id)}, %{world | boots: boots}}
    end
  end

  defp bridge_state(world), do: :sys.get_state(world.bridge)

  defp bridge_closed?(world), do: bridge_state(world).status == :closed

  defp current_handle(world) do
    state = bridge_state(world)
    if world.mode == :managed, do: state.adapter_state.port, else: state.port
  end

  defp current_generation(world) do
    case current_handle(world) do
      nil -> nil
      handle -> Subprocess.identity(handle)
    end
  end

  defp drain_outbox(world) do
    case AdapterBridge.receive_message(world.bridge, 0) do
      {:ok, json} -> world |> observe(traced(Jason.decode!(json))) |> drain_outbox()
      {:error, _reason} -> world
    end
  end

  # -- invariants -------------------------------------------------------------------

  defp observe(world, %{"id" => id} = message) when not is_map_key(message, "method") do
    request = world.requests[id]
    assert request, violation(world, "a response to unknown request #{inspect(id)}")

    assert request.answers == 0,
           violation(
             world,
             "request #{id} (#{request.method}) was answered twice: " <>
               inspect(message)
           )

    world = put_in(world.requests[id].answers, 1)
    observe_answer(world, id, request, message)
  end

  defp observe(world, %{"method" => "session/update", "params" => params} = message) do
    if barrier_name(message), do: world, else: observe_update(world, params, message)
  end

  defp observe(world, _message), do: world

  defp observe_update(world, params, message) do
    session = params["sessionId"]
    update = params["update"] || %{}

    allowed? =
      session == world.current or
        Enum.any?(world.requests, fn {_id, request} ->
          request.answers == 0 and request.kind == :setup and request.target == session
        end)

    assert allowed?,
           violation(
             world,
             "an update for session #{inspect(session)} while the client is on " <>
               "#{inspect(world.current)}: #{inspect(message)}"
           )

    check_turn_text(world, update_text(update), session, message)
  end

  defp observe_answer(world, id, %{kind: :setup} = request, %{"result" => result}) do
    session = if request.target == :new, do: result["sessionId"], else: request.target

    assert world.pi.session && world.pi.session.id == session,
           violation(
             world,
             "setup #{id} answered for session #{inspect(session)} while Pi is on " <>
               "#{inspect(world.pi.session)}"
           )

    known = if session in world.known, do: world.known, else: world.known ++ [session]
    %{world | current: session, known: known}
  end

  defp observe_answer(world, id, %{kind: :prompt} = request, %{"result" => result}) do
    meta = get_in(result, ["_meta", "ex_mcp"]) || %{}

    if result["stopReason"] == "end_turn" and request.turn? do
      assert MapSet.member?(world.settled, id),
             violation(
               world,
               "prompt #{id} ended without its own turn settling: #{inspect(result)}"
             )

      assert meta["sessionId"] == request.session,
             violation(world, "prompt #{id} answered for session #{inspect(meta["sessionId"])}")
    end

    check_tags(world, meta["text"], id, "prompt #{id}'s answer")
    world
  end

  defp observe_answer(world, _id, _request, _message), do: world

  defp check_turn_text(world, nil, _session, _message), do: world

  defp check_turn_text(world, text, session, message) do
    for [_, tag] <- Regex.scan(~r/\[#(\d+)\]/, text) do
      tag = String.to_integer(tag)
      prompt = world.requests[tag]

      assert prompt && prompt.answers == 0,
             violation(
               world,
               "a chunk of turn #{tag} after its prompt was answered: " <>
                 inspect(message)
             )

      assert prompt.session == session,
             violation(world, "a chunk of turn #{tag} for session #{inspect(session)}")
    end

    world
  end

  defp check_tags(_world, nil, _id, _what), do: :ok

  defp check_tags(world, text, id, what) do
    for [_, tag] <- Regex.scan(~r/\[#(\d+)\]/, text) do
      assert String.to_integer(tag) == id,
             violation(world, "#{what} holds text of turn #{tag}")
    end

    :ok
  end

  defp update_text(%{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => text}}),
    do: text

  defp update_text(_update), do: nil

  defp check_session_agreement(%{closed?: true} = world, _command), do: world

  defp check_session_agreement(world, _command) do
    adapter = bridge_state(world).adapter_state

    idle? =
      adapter.op_in_flight == nil and adapter.op_queue == [] and is_nil(adapter.desynced)

    if idle? and world.current != nil do
      assert adapter.session_id == world.current,
             violation(
               world,
               "the idle adapter serves #{inspect(adapter.session_id)} but the client is on " <>
                 "#{inspect(world.current)}"
             )
    end

    if idle? and world.pi.handle != nil and not world.pi.broken? and
         is_binary(adapter.session_file) do
      assert world.pi.session.file == adapter.session_file,
             violation(
               world,
               "the idle adapter claims #{adapter.session_file} but Pi is on " <>
                 "#{inspect(world.pi.session)}"
             )
    end

    world
  end

  # -- the end ------------------------------------------------------------------------

  defp drain(%{closed?: true} = world, _round), do: world

  defp drain(world, round) when round > @drain_limit,
    do: flunk(violation(world, "Pi and the adapter never went quiet"))

  defp drain(world, round) do
    world = %{world | settled: MapSet.new(), trace: [:drain | world.trace]}

    cond do
      world.pi.handle == nil ->
        world

      world.pi.broken? ->
        world |> pi_exit() |> after_step(:exit) |> drain(round + 1)

      world.pi.pending != [] ->
        {:reply, 0, :ok} |> exec(world) |> after_step(:reply) |> drain(round + 1)

      match?(%{ended?: false}, world.pi.turn) ->
        :agent_end |> exec(world) |> after_step(:agent_end) |> drain(round + 1)

      world.pi.turn != nil ->
        :agent_settled |> exec(world) |> after_step(:agent_settled) |> drain(round + 1)

      true ->
        world
    end
  end

  defp final_checks(%{closed?: true} = world), do: world

  defp final_checks(world) do
    for {id, request} <- Enum.sort(world.requests) do
      assert request.answers == 1,
             violation(world, "request #{id} (#{request.method}) was never answered")
    end

    adapter = bridge_state(world).adapter_state

    for {field, empty} <- [
          op_in_flight: nil,
          op_queue: [],
          pending_controls: %{},
          control_groups: %{},
          pending_prompt: nil,
          pending_extension_ui: %{}
        ] do
      assert Map.fetch!(adapter, field) == empty,
             violation(world, "#{field} did not drain: #{inspect(Map.fetch!(adapter, field))}")
    end

    assert PromptQueue.empty?(adapter.prompt_queue),
           violation(world, "the prompt queue did not drain")

    world
  end

  # PI_MODEL_TRACE=1 prints every step, Pi line and ACP message.
  defp trace(text) do
    if System.get_env("PI_MODEL_TRACE") == "1", do: IO.puts(text)
  end

  defp traced(message) do
    trace("acp <- #{Jason.encode!(message)}")
    message
  end

  defp violation(world, text) do
    "#{world.mode} Pi: #{text}\n  after: " <>
      (world.trace |> Enum.reverse() |> Enum.reject(&(&1 == :drain)) |> inspect(limit: :infinity))
  end
end
