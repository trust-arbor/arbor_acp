defmodule Arbor.ACP.Adapters.PiHomeLifecycleTest do
  use ExUnit.Case, async: true
  alias Arbor.ACP.Adapters.Pi
  import Arbor.ACP.TestHelpers, only: [wait_until: 1]

  setup do
    root = Path.join(System.tmp_dir!(), "pi_home_lifecycle_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    cli = Path.join(root, "pi")

    File.write!(cli, """
    #!/bin/sh
    trap 'if [ -d "$PI_CODING_AGENT_DIR" ]; then echo present; else echo missing; fi > "#{root}/stopped"' EXIT
    echo "$PI_CODING_AGENT_DIR" > "#{root}/started"
    while IFS= read -r _line; do :; done
    """)

    File.chmod!(cli, 0o755)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, cli: cli}
  end

  test "managed close stops its process before removing the home and the next session gets a live home",
       %{root: root, cli: cli} do
    {:ok, state} =
      Pi.init(cwd: root, cli_path: cli, session_map_path: Path.join(root, "map.json"))

    bootstrap = state.auth_home_opts[:agent_dir]
    File.write!(Path.join(bootstrap, "auth.json"), "temporary login")
    result = Pi.translate_outbound(request(1, "session/new", %{"cwd" => root}), state)
    state = elem(result, tuple_size(result) - 1)
    assert state.port != nil
    initial = state.opts[:agent_dir]
    assert initial != bootstrap
    assert File.read!(Path.join(initial, "auth.json")) == "temporary login"
    assert :ok = wait_until(fn -> File.exists?(Path.join(root, "started")) end)
    assert String.trim(File.read!(Path.join(root, "started"))) == initial
    result = Pi.translate_outbound(request(2, "session/close", %{}), state)
    state = elem(result, tuple_size(result) - 1)
    assert state.cleanup_result == :ok
    assert state.port == nil
    refute File.exists?(initial)
    assert File.dir?(bootstrap)
    # The child sees its home until stdin is closed and its exit trap runs.
    assert :ok = wait_until(fn -> File.exists?(Path.join(root, "stopped")) end)
    assert String.trim(File.read!(Path.join(root, "stopped"))) == "present"
    result = Pi.translate_outbound(request(3, "session/new", %{"cwd" => root}), state)
    state = elem(result, tuple_size(result) - 1)
    assert state.port != nil
    assert state.opts[:agent_dir] != initial
    assert File.dir?(state.opts[:agent_dir])
    home = state.opts[:agent_dir]
    assert %Pi{} = Pi.shutdown(state)
    refute File.exists?(home)
    refute File.exists?(bootstrap)
  end

  test "unmanaged close retains the home of the continuing child", %{root: root} do
    {:ok, state} =
      Pi.init(cwd: root, managed: false, session_map_path: Path.join(root, "map.json"))

    home = state.opts[:agent_dir]
    result = Pi.translate_outbound(request(1, "session/close", %{}), state)
    state = elem(result, tuple_size(result) - 1)
    assert File.dir?(home)
    assert state.opts[:agent_dir] == home
    assert %Pi{} = Pi.shutdown(state)
    assert File.dir?(home)
  end

  test "unexpected managed exit retires its private home before a new session", %{
    root: root,
    cli: cli
  } do
    {:ok, state} =
      Pi.init(cwd: root, cli_path: cli, session_map_path: Path.join(root, "map.json"))

    result = Pi.translate_outbound(request(1, "session/new", %{"cwd" => root}), state)
    state = elem(result, tuple_size(result) - 1)
    home = state.opts[:agent_dir]
    File.write!(Path.join(home, "old-session"), "private")
    generation = Arbor.ACP.AdapterSupport.Subprocess.identity(state.port)
    result = Pi.handle_adapter_message({:arbor_rpc, generation, {:closed, :normal, ""}}, state)
    state = elem(result, tuple_size(result) - 1)
    assert state.cleanup_result == :ok
    refute File.exists?(home)
    result = Pi.translate_outbound(request(2, "session/new", %{"cwd" => root}), state)
    state = elem(result, tuple_size(result) - 1)
    assert state.opts[:agent_dir] != home
    refute File.exists?(Path.join(state.opts[:agent_dir], "old-session"))
    assert %Pi{} = Pi.shutdown(state)
  end

  defp request(id, method, params), do: %{"id" => id, "method" => method, "params" => params}
end
