defmodule Arbor.ACP.Adapters.ClaudeHomeLifecycleTest do
  use ExUnit.Case, async: true
  alias Arbor.ACP.Adapters.ClaudeSDK
  alias Arbor.ACP.Adapters.ClaudeSDK.SessionStore
  import Arbor.ACP.TestHelpers, only: [wait_until: 1]

  setup do
    root =
      Path.join(System.tmp_dir!(), "claude_home_lifecycle_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    log = Path.join(root, "homes")
    cli = Path.join(root, "claude")

    File.write!(cli, """
    #!/bin/sh
    printf '%s\\n' "$CLAUDE_CONFIG_DIR" >> "#{log}"
    while IFS= read -r _line; do :; done
    """)

    File.chmod!(cli, 0o755)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, cli: cli, log: log}
  end

  test "managed sessions share a connection home and close removes only its history", %{
    root: root,
    cli: cli,
    log: log
  } do
    {:ok, state} = ClaudeSDK.init(cwd: root, cli_path: cli)
    bootstrap = state.opts[:claude_config_dir]
    File.write!(Path.join(bootstrap, ".credentials.json"), "temporary login")
    File.write!(Path.join(bootstrap, "settings.json"), "{}")
    {a, state} = new_session(state, root, 1)
    {b, state} = new_session(state, root, 2)
    assert SessionStore.valid_session_id?(a)
    assert SessionStore.valid_session_id?(b)
    home_a = state.session_homes[a][:claude_config_dir]
    home_b = state.session_homes[b][:claude_config_dir]
    assert home_a == home_b and home_a == bootstrap
    assert state.session_processes[a].handle != state.session_processes[b].handle
    assert File.read!(Path.join(home_a, ".credentials.json")) == "temporary login"
    assert File.read!(Path.join(home_a, "settings.json")) == "{}"
    assert Bitwise.band(File.stat!(home_a).mode, 0o777) == 0o700
    write_transcript(home_a, root, a, "A")
    write_transcript(home_b, root, b, "B")

    assert :ok = wait_until(fn -> length(lines(log)) == 2 end)
    assert MapSet.new(lines(log)) == MapSet.new([home_a, home_b])

    {:reply, %{}, state} =
      ClaudeSDK.translate_outbound(request(3, "session/close", %{"sessionId" => a}), state)

    assert File.dir?(home_a)

    assert {:error, _} =
             SessionStore.read_session_messages(a, claude_config_dir: home_a, cwd: root)

    assert {:ok, [_]} =
             SessionStore.read_session_messages(b, claude_config_dir: home_b, cwd: root)

    assert File.read!(Path.join(bootstrap, ".credentials.json")) == "temporary login"
    assert File.dir?(home_b)
    assert Map.has_key?(state.session_processes, b)
    assert {:ok, _} = ClaudeSDK.shutdown(state)
    refute File.exists?(home_b)
  end

  test "list, load and fork use the shared connection store", %{root: root, cli: cli} do
    {:ok, state} = ClaudeSDK.init(cwd: root, cli_path: cli)
    {a, state} = new_session(state, root, 1)
    {b, state} = new_session(state, root, 2)
    home_a = state.session_homes[a][:claude_config_dir]
    home_b = state.session_homes[b][:claude_config_dir]
    write_transcript(home_a, root, a, "parent A")
    write_transcript(home_b, root, b, "parent B")
    assert {:ok, sessions, _} = ClaudeSDK.list_sessions(%{"cwd" => root}, state)
    assert MapSet.new(Enum.map(sessions, & &1["sessionId"])) == MapSet.new([a, b])

    assert {:messages_and_reply, replay, %{"sessionId" => ^a}, state} =
             ClaudeSDK.translate_outbound(
               request(3, "session/load", %{"sessionId" => a, "cwd" => root}),
               state
             )

    assert [
             %{
               "params" => %{
                 "sessionId" => ^a,
                 "update" => %{"content" => %{"text" => "parent A"}}
               }
             }
           ] = replay

    assert state.session_homes[a][:claude_config_dir] == home_a

    assert {:ok, %{"sessionId" => child}, state} =
             ClaudeSDK.fork_session(%{"sessionId" => a, "cwd" => root}, state)

    home_child = state.session_homes[child][:claude_config_dir]
    assert home_child == home_a and home_child == home_b

    assert {:ok, [%{"sessionId" => ^child}]} =
             SessionStore.read_session_messages(child, claude_config_dir: home_child, cwd: root)

    assert {:ok, [%{"sessionId" => ^a}]} =
             SessionStore.read_session_messages(a, claude_config_dir: home_a, cwd: root)

    assert {:ok, _} = ClaudeSDK.shutdown(state)
  end

  test "a caller-owned persistent home is retained after all sessions close", %{
    root: root,
    cli: cli
  } do
    home = Path.join(root, "arbor_acp_runtime_home_caller")
    File.mkdir!(home)
    File.write!(Path.join(home, "credentials"), "host owned")
    {:ok, state} = ClaudeSDK.init(cwd: root, cli_path: cli, claude_config_dir: home)
    {a, state} = new_session(state, root, 1)
    {_b, state} = new_session(state, root, 2)
    write_transcript(home, root, a, "persistent")

    assert {:reply, %{}, state} =
             ClaudeSDK.translate_outbound(request(3, "session/close", %{"sessionId" => a}), state)

    assert {:ok, [_]} = SessionStore.read_session_messages(a, claude_config_dir: home, cwd: root)
    assert {:ok, _} = ClaudeSDK.shutdown(state)
    assert File.read!(Path.join(home, "credentials")) == "host owned"
  end

  test "terminal authentication restarts idle children against shared native credentials", %{
    root: root,
    cli: cli
  } do
    {:ok, state} = ClaudeSDK.init(cwd: root, cli_path: cli, model: "sonnet")
    {a, state} = new_session(state, root, 1)
    {_b, state} = new_session(state, root, 2)
    before = state.session_processes
    home = state.opts[:claude_config_dir]
    write_transcript(home, root, a, "keep conversation")
    File.write!(Path.join(home, ".credentials.json"), "new login")

    assert {:reply, %{}, state} =
             ClaudeSDK.translate_outbound(
               request(3, "authenticate", %{"methodId" => "claude-login"}),
               state
             )

    for {id, old} <- before do
      assert state.session_processes[id].handle != old.handle
      assert state.session_processes[id].fields.claude_session_id == old.fields.claude_session_id
      assert state.session_processes[id].fields.model == "sonnet"
      assert state.session_homes[id][:claude_config_dir] == home
    end

    assert {:ok, [_]} = SessionStore.read_session_messages(a, claude_config_dir: home, cwd: root)
    assert {:ok, _} = ClaudeSDK.shutdown(state)
  end

  test "authentication refuses to restart a child with active work", %{root: root, cli: cli} do
    alias Arbor.ACP.Adapters.Internal.PromptQueue
    {:ok, state} = ClaudeSDK.init(cwd: root, cli_path: cli)
    {_id, state} = new_session(state, root, 1)
    handle = state.port

    for busy <- [
          %{pending_prompt_id: "prompt"},
          %{pending_client_requests: %{"request" => %{}}},
          %{prompt_queue: PromptQueue.from_list([%{}])}
        ] do
      busy_state = Map.merge(state, busy)

      assert {:error, reason, rejected} =
               ClaudeSDK.translate_outbound(
                 request(2, "authenticate", %{"methodId" => "claude-login"}),
                 busy_state
               )

      assert reason =~ "work is active"
      assert rejected.port == handle
      assert Arbor.ACP.AdapterSupport.Subprocess.connected?(handle)
    end

    assert {:ok, _} = ClaudeSDK.shutdown(state)
  end

  test "separate connection owners receive different private homes" do
    parent = self()

    owners =
      for _ <- 1..2 do
        spawn(fn ->
          {:ok, state} = ClaudeSDK.init([])
          send(parent, {:home, self(), state.opts[:claude_config_dir]})

          receive do
            :close -> assert {:ok, _} = ClaudeSDK.shutdown(state)
          end
        end)
      end

    homes =
      for owner <- owners do
        assert_receive {:home, ^owner, home}
        assert File.dir?(home)
        home
      end

    assert length(Enum.uniq(homes)) == 2

    for owner <- owners do
      ref = Process.monitor(owner)
      send(owner, :close)
      assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
    end

    for home <- homes, do: refute(File.exists?(home))
  end

  test "failed fork launch rolls back its transcript and home", %{root: root, cli: cli} do
    {:ok, state} = ClaudeSDK.init(cwd: root, cli_path: cli)
    {parent, state} = new_session(state, root, 1)
    home = state.session_homes[parent][:claude_config_dir]
    write_transcript(home, root, parent, "keep parent")
    state = %{state | opts: Keyword.put(state.opts, :cli_path, Path.join(root, "missing-cli"))}
    original_homes = state.session_homes

    assert {:error, _reason, failed} =
             ClaudeSDK.fork_session(%{"sessionId" => parent, "cwd" => root}, state)

    assert failed.session_homes == original_homes

    assert {:ok, [%{"sessionId" => ^parent}], _} =
             ClaudeSDK.list_sessions(%{"cwd" => root}, failed)

    assert {:ok, [%{"sessionId" => ^parent}]} =
             SessionStore.read_session_messages(parent, claude_config_dir: home, cwd: root)

    assert {:ok, _} = ClaudeSDK.shutdown(failed)
  end

  test "unmanaged close and shutdown retain the continuing process home", %{root: root, cli: cli} do
    {:ok, state} = ClaudeSDK.init(cwd: root, cli_path: cli, managed: false)
    home = state.opts[:claude_config_dir]
    {id, state} = new_session(state, root, 1)

    result =
      ClaudeSDK.translate_outbound(request(2, "session/close", %{"sessionId" => id}), state)

    state = elem(result, tuple_size(result) - 1)
    assert File.dir?(home)
    assert {:ok, _} = ClaudeSDK.shutdown(state)
    assert File.dir?(home)
  end

  test "repeated failed launches do not retain new child homes", %{root: root} do
    {:ok, state} = ClaudeSDK.init(cwd: root, cli_path: Path.join(root, "missing-cli"))

    owned = fn ->
      Process.get({Arbor.ACP.Adapters.Internal.RuntimeHome, :owned_homes}, %{}) |> map_size()
    end

    initial = owned.()

    state =
      Enum.reduce(1..3, state, fn id, state ->
        assert {:error, _reason, state} =
                 ClaudeSDK.translate_outbound(request(id, "session/new", %{"cwd" => root}), state)

        assert state.session_homes == %{}
        assert owned.() == initial
        state
      end)

    assert {:ok, _} = ClaudeSDK.shutdown(state)
  end

  test "unconfirmed cleanup preserves the home and answers pending work once", %{
    root: root,
    cli: cli
  } do
    {:ok, state} = ClaudeSDK.init(cwd: root, cli_path: cli)
    {id, state} = new_session(state, root, 1)
    home = state.session_homes[id][:claude_config_dir]
    handle = state.session_processes[id].handle
    invalid = %{handle | generation: make_ref()}
    processes = Map.update!(state.session_processes, id, &%{&1 | handle: invalid})

    state = %{
      state
      | port: invalid,
        session_processes: processes,
        pending_prompt_id: "prompt",
        active_prompt_session_id: id
    }

    assert {:messages, messages, failed} =
             ClaudeSDK.translate_outbound(
               request(2, "session/close", %{"sessionId" => id}),
               state
             )

    assert [
             %{"id" => "prompt", "result" => %{"stopReason" => "cancelled"}},
             %{"id" => 2, "error" => %{}}
           ] = messages

    assert failed.cleanup_result != :ok
    assert File.dir?(home)
    assert :ok = Arbor.ACP.AdapterSupport.Subprocess.command(handle, "{}\n")

    assert {:error, _reason, ^failed} =
             ClaudeSDK.translate_outbound(request(3, "session/new", %{"cwd" => root}), failed)

    recovered = %{
      failed
      | port: handle,
        session_processes: Map.update!(failed.session_processes, id, &%{&1 | handle: handle})
    }

    assert {:ok, closed} = ClaudeSDK.shutdown(recovered)
    assert closed.cleanup_result == :ok
    refute File.exists?(home)
  end

  test "delete preserves the transcript when child cleanup is unconfirmed", %{
    root: root,
    cli: cli
  } do
    {:ok, state} = ClaudeSDK.init(cwd: root, cli_path: cli)
    {id, state} = new_session(state, root, 1)
    home = state.session_homes[id][:claude_config_dir]
    write_transcript(home, root, id, "keep")
    handle = state.session_processes[id].handle
    invalid = %{handle | generation: make_ref()}

    state = %{
      state
      | port: invalid,
        session_processes: Map.update!(state.session_processes, id, &%{&1 | handle: invalid})
    }

    assert {:error, _, failed} =
             ClaudeSDK.translate_outbound(
               request(2, "session/delete", %{"sessionId" => id, "cwd" => root}),
               state
             )

    assert {:ok, [%{"sessionId" => ^id}]} =
             SessionStore.read_session_messages(id, claude_config_dir: home, cwd: root)

    recovered = %{
      failed
      | port: handle,
        session_processes: Map.update!(failed.session_processes, id, &%{&1 | handle: handle})
    }

    assert {:ok, _} = ClaudeSDK.shutdown(recovered)
  end

  test "a new session cannot replace an already open caller id", %{root: root, cli: cli} do
    {:ok, state} = ClaudeSDK.init(cwd: root, cli_path: cli)
    {id, state} = new_session(state, root, 1)
    handle = state.port

    assert {:error, reason, state} =
             ClaudeSDK.translate_outbound(
               request(2, "session/new", %{"sessionId" => id, "cwd" => root}),
               state
             )

    assert reason =~ "already open"
    assert state.port == handle
    assert {:ok, _} = ClaudeSDK.shutdown(state)
  end

  defp new_session(state, cwd, id) do
    {:reply, %{"sessionId" => sid}, state} =
      ClaudeSDK.translate_outbound(request(id, "session/new", %{"cwd" => cwd}), state)

    {sid, state}
  end

  defp request(id, method, params), do: %{"id" => id, "method" => method, "params" => params}

  defp lines(path) do
    case File.read(path) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      _ -> []
    end
  end

  defp write_transcript(home, cwd, sid, text) do
    dir = Path.join([home, "projects", SessionStore.project_key(cwd)])
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, sid <> ".jsonl"),
      Jason.encode!(%{
        "sessionId" => sid,
        "cwd" => cwd,
        "type" => "user",
        "message" => %{"role" => "user", "content" => text}
      }) <> "\n"
    )
  end
end
