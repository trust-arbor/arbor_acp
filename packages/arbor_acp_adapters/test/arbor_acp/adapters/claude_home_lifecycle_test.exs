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

  test "managed sessions launch distinct homes and closing one leaves the other live", %{
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
    assert home_a != home_b

    for home <- [home_a, home_b] do
      assert File.read!(Path.join(home, ".credentials.json")) == "temporary login"
      refute File.exists?(Path.join(home, "settings.json"))
      assert Bitwise.band(File.stat!(Path.join(home, ".credentials.json")).mode, 0o777) == 0o600
    end

    assert :ok = wait_until(fn -> length(lines(log)) == 2 end)
    assert MapSet.new(lines(log)) == MapSet.new([home_a, home_b])

    {:reply, %{}, state} =
      ClaudeSDK.translate_outbound(request(3, "session/close", %{"sessionId" => a}), state)

    refute File.exists?(home_a)
    assert File.dir?(home_b)
    assert Map.has_key?(state.session_processes, b)
    assert {:ok, _} = ClaudeSDK.shutdown(state)
    refute File.exists?(home_b)
  end

  test "list, load and fork use the home associated with each session", %{root: root, cli: cli} do
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
    refute home_child in [home_a, home_b]

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
    {_a, state} = new_session(state, root, 1)
    {_b, state} = new_session(state, root, 2)
    assert {:ok, _} = ClaudeSDK.shutdown(state)
    assert File.read!(Path.join(home, "credentials")) == "host owned"
  end

  test "terminal authentication seeds a session created before login", %{root: root, cli: cli} do
    {:ok, state} = ClaudeSDK.init(cwd: root, cli_path: cli)
    {_id, state} = new_session(state, root, 1)
    File.write!(Path.join(state.opts[:claude_config_dir], ".credentials.json"), "new login")

    assert {:reply, %{}, state} =
             ClaudeSDK.translate_outbound(
               request(2, "authenticate", %{"methodId" => "claude-login"}),
               state
             )

    for {_id, opts} <- state.session_homes do
      assert File.read!(Path.join(opts[:claude_config_dir], ".credentials.json")) == "new login"
    end

    assert {:ok, _} = ClaudeSDK.shutdown(state)
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
