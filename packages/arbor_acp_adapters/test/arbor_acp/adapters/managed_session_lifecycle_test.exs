defmodule Arbor.ACP.Adapters.ManagedSessionLifecycleTest do
  use ExUnit.Case, async: true
  alias Arbor.ACP.Adapters.{ClaudeSDK, Codex}
  alias Arbor.ACP.AdapterSupport.Subprocess
  import Arbor.ACP.TestHelpers, only: [wait_until: 1]

  setup do
    root = Path.join(System.tmp_dir!(), "managed_lifecycle_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    cli = Path.join(root, "claude")

    File.write!(cli, """
    #!/bin/sh
    printf '%s\n' "$@" > "#{root}/argv.$$"
    while IFS= read -r _line; do :; done
    """)

    File.chmod!(cli, 0o755)

    {:ok, state} =
      ClaudeSDK.init(cwd: root, cli_path: cli, claude_config_dir: Path.join(root, "config"))

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, cli: cli, state: state}
  end

  test "monitored exit answers only the affected session prompt", %{state: state, root: root} do
    {a, state} = new_session(state, root, "a")
    state = %{state | pending_prompt_id: "prompt-a", active_prompt_session_id: a}
    {b, state} = new_session(state, root, "b")
    state = %{state | pending_prompt_id: "prompt-b", active_prompt_session_id: b}
    entry = state.session_processes[a]
    [actor] = Arbor.RPC.Subprocess.linked_processes(entry.handle)

    assert {:messages, messages, state} =
             ClaudeSDK.handle_adapter_message(
               {:DOWN, entry.monitor, :process, actor, :killed},
               state
             )

    assert Enum.any?(messages, &(&1["id"] == "prompt-a"))
    refute Enum.any?(messages, &(&1["id"] == "prompt-b"))
    assert state.session_processes[b].fields.pending_prompt_id == "prompt-b"
    assert {:ok, _} = ClaudeSDK.shutdown(state)
  end

  test "final result without newline settles before EOF cancellation", %{state: state, root: root} do
    {a, state} = new_session(state, root, "a")
    state = %{state | pending_prompt_id: "prompt"}
    handle = state.session_processes[a].handle

    result =
      Jason.encode!(%{
        "type" => "result",
        "subtype" => "success",
        "result" => "done",
        "stop_reason" => "end_turn",
        "usage" => %{}
      })

    message = {:arbor_rpc, Subprocess.identity(handle), {:closed, :normal, result}}
    assert {:messages, messages, _state} = ClaudeSDK.handle_adapter_message(message, state)
    replies = Enum.filter(messages, &(&1["id"] == "prompt"))
    assert [%{"result" => %{"stopReason" => "end_turn"}}] = replies
  end

  test "missing history does not launch or register a managed child", %{state: state, root: root} do
    id = "123e4567-e89b-12d3-a456-426614174000"

    assert {:error, _reason, state} =
             ClaudeSDK.translate_outbound(
               request(1, "session/load", %{"sessionId" => id, "cwd" => root}),
               state
             )

    assert state.session_processes == %{}
    assert state.port == nil
    refute Enum.any?(File.ls!(root), &String.starts_with?(&1, "argv."))
    assert {:ok, _} = ClaudeSDK.shutdown(state)
  end

  test "MCP paths retain configured cwd while child cwd changes", %{state: state, root: root} do
    File.write!(Path.join(root, "mcp.json"), "{}")
    subdir = Path.join(root, "subdir")
    File.mkdir!(subdir)
    state = %{state | opts: Keyword.put(state.opts, :mcp_config_path, "mcp.json")}
    {_a, state} = new_session(state, subdir, "a")
    assert :ok = wait_until(fn -> length(argv_files(root)) == 1 end)
    argv = argv_files(root) |> hd() |> File.read!()
    assert argv =~ Path.join(root, "mcp.json")
    assert {:ok, _} = ClaudeSDK.shutdown(state)
  end

  test "configured native session id is not reused by independent new children", %{
    state: state,
    root: root
  } do
    old = "123e4567-e89b-12d3-a456-426614174000"
    state = %{state | opts: Keyword.put(state.opts, :session_id, old)}
    {_a, state} = new_session(state, root, "a")
    {_b, state} = new_session(state, root, "b")
    assert :ok = wait_until(fn -> length(argv_files(root)) == 2 end)

    ids =
      Enum.map(argv_files(root), fn path ->
        args = String.split(File.read!(path), "\n", trim: true)
        index = Enum.find_index(args, &(&1 == "--session-id"))
        Enum.at(args, index + 1)
      end)

    assert length(Enum.uniq(ids)) == 2
    refute old in ids
    assert {:ok, _} = ClaudeSDK.shutdown(state)
  end

  test "listed persisted Codex threads can be resumed in their original workspace", %{root: root} do
    {:ok, state} = Codex.init(cwd: root, workspace_roots: [root])

    {:ok, wire, state} =
      Codex.translate_outbound(request(1, "session/list", %{"cwd" => root}), state)

    native = Jason.decode!(wire)

    response = %{
      "id" => native["id"],
      "result" => %{"data" => [%{"id" => "persisted", "cwd" => root}]}
    }

    assert {:messages, _, state} = Codex.translate_inbound(Jason.encode!(response), state)

    assert {:ok, _, _} =
             Codex.translate_outbound(
               request(2, "session/resume", %{"sessionId" => "persisted", "cwd" => root}),
               state
             )
  end

  test "a broad allowed root does not make sibling Codex workspaces identical", %{root: root} do
    a = Path.join(root, "a")
    b = Path.join(root, "b")
    File.mkdir!(a)
    File.mkdir!(b)
    {:ok, state} = Codex.init(cwd: root, workspace_roots: [root])
    state = %{state | thread_bindings: %{"thread-a" => a}}

    assert {:error, reason, _} =
             Codex.translate_outbound(
               request(1, "session/resume", %{"sessionId" => "thread-a", "cwd" => b}),
               state
             )

    assert reason =~ "not bound"
  end

  defp argv_files(root), do: Path.wildcard(Path.join(root, "argv.*"))

  defp new_session(state, cwd, id) do
    {:reply, %{"sessionId" => sid}, state} =
      ClaudeSDK.translate_outbound(
        request(id, "session/new", %{"cwd" => cwd, "sessionId" => id}),
        state
      )

    {sid, state}
  end

  defp request(id, method, params), do: %{"id" => id, "method" => method, "params" => params}
end
