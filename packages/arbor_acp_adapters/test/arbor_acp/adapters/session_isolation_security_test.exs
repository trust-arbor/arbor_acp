defmodule Arbor.ACP.Adapters.SessionIsolationSecurityTest do
  @moduledoc """
  Regression tests for cross-session isolation.

  1. Codex `session/load` and `session/resume` must not accept another
     session's thread.
  2. Claude session-store calls must reject a `cwd` outside the session's
     workspace roots, including symlink escapes.
  3. Two Claude ACP sessions on one connection must not share a Claude
     process.
  """

  use ExUnit.Case, async: true

  import Arbor.ACP.TestHelpers, only: [wait_until: 1]

  alias Arbor.ACP.AdapterBridge
  alias Arbor.ACP.Adapters.ClaudeSDK
  alias Arbor.ACP.Adapters.Codex

  @moduletag timeout: 10_000

  setup do
    root =
      System.tmp_dir!()
      |> Path.join("session_isolation_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "Codex thread binding" do
    test "session A cannot load or resume session B's thread", %{root: root} do
      ws_a = Path.join(root, "ws-a")
      ws_b = Path.join(root, "ws-b")
      File.mkdir_p!(ws_a)
      File.mkdir_p!(ws_b)

      {:ok, state} = Codex.init(workspace_roots: [ws_a, ws_b], cwd: ws_a)
      state = start_live_thread(state, "thread-a", ws_a)
      state = start_live_thread(state, "thread-b", ws_b)

      for {method, id} <- [{"session/load", "acp-load"}, {"session/resume", "acp-resume"}] do
        msg = %{
          "method" => method,
          "id" => id,
          "params" => %{"sessionId" => "thread-b", "cwd" => ws_a}
        }

        assert {:error, reason, ^state} = Codex.translate_outbound(msg, state)

        assert reason =~ ~r/not bound|workspace|session|thread/i,
               "#{method} must reject another session's thread, got: #{inspect(reason)}"
      end
    end
  end

  describe "Claude workspace cwd" do
    test "session-store calls reject a cwd outside the workspace roots", %{root: root} do
      workspace = Path.join(root, "ws")
      outside = Path.join(root, "outside")
      File.mkdir_p!(workspace)
      File.mkdir_p!(outside)

      {:ok, state} =
        ClaudeSDK.init(
          cwd: workspace,
          workspace_roots: [workspace],
          claude_config_dir: Path.join(root, "claude")
        )

      session_id = "123e4567-e89b-12d3-a456-426614174000"

      for {method, params} <- [
            {"session/load", %{"sessionId" => session_id, "cwd" => outside}},
            {"session/resume", %{"sessionId" => session_id, "cwd" => outside}},
            {"session/list", %{"cwd" => outside}}
          ] do
        msg = %{"id" => 1, "method" => method, "params" => params}

        assert {:error, reason, _state} = ClaudeSDK.translate_outbound(msg, state)

        assert reason =~ ~r/not authorized|workspace/i,
               "#{method} must reject a cwd outside the roots, got: #{inspect(reason)}"

        refute reason =~ "was not found"
      end

      assert {:error, reason, _state} =
               ClaudeSDK.list_sessions(%{"cwd" => outside}, state)

      assert reason =~ ~r/not authorized|workspace/i
    end

    test "session-store calls reject a cwd that escapes the roots through a symlink",
         %{root: root} do
      workspace = Path.join(root, "ws")
      outside = Path.join(root, "outside")
      File.mkdir_p!(workspace)
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(workspace, "link"))

      {:ok, state} =
        ClaudeSDK.init(
          cwd: workspace,
          workspace_roots: [workspace],
          claude_config_dir: Path.join(root, "claude")
        )

      escaped = Path.join(workspace, "link")

      msg = %{
        "id" => 1,
        "method" => "session/load",
        "params" => %{
          "sessionId" => "123e4567-e89b-12d3-a456-426614174000",
          "cwd" => escaped
        }
      }

      assert {:error, reason, _state} = ClaudeSDK.translate_outbound(msg, state)
      assert reason =~ ~r/not authorized|workspace/i
      refute reason =~ "was not found"
    end
  end

  describe "Claude process isolation" do
    test "two ACP sessions on one connection do not share a Claude process", %{root: root} do
      ws_a = Path.join(root, "ws-a")
      ws_b = Path.join(root, "ws-b")
      File.mkdir_p!(ws_a)
      File.mkdir_p!(ws_b)

      pid_log = Path.join(root, "pids.log")
      cli = Path.join(root, "claude")

      File.write!(cli, """
      #!/bin/sh
      printf '%s %s\\n' "$$" "$(pwd)" >> "#{pid_log}"
      while IFS= read -r _line; do :; done
      """)

      File.chmod!(cli, 0o755)

      {:ok, bridge} =
        AdapterBridge.start_link(
          adapter: ClaudeSDK,
          adapter_opts: [
            cli_path: cli,
            cwd: root,
            workspace_roots: [ws_a, ws_b],
            claude_config_dir: Path.join(root, "claude")
          ]
        )

      try do
        send_request(bridge, 1, "initialize", %{
          "protocolVersion" => 1,
          "clientCapabilities" => %{}
        })

        assert %{"result" => _} = receive_response(bridge, 1)

        send_request(bridge, 2, "session/new", %{"cwd" => ws_a, "sessionId" => "session-a"})
        assert %{"result" => _} = receive_response(bridge, 2)

        send_request(bridge, 3, "session/new", %{"cwd" => ws_b, "sessionId" => "session-b"})
        assert %{"result" => _} = receive_response(bridge, 3)

        wait_until(fn ->
          pid_log
          |> read_pid_cwd_entries()
          |> then(fn entries ->
            session_pids(entries, ws_a) != [] and session_pids(entries, ws_b) != []
          end)
        end)

        entries = read_pid_cwd_entries(pid_log)
        pids_a = session_pids(entries, ws_a)
        pids_b = session_pids(entries, ws_b)

        assert pids_a != []
        assert pids_b != []

        assert MapSet.disjoint?(MapSet.new(pids_a), MapSet.new(pids_b)),
               "sessions A and B shared a Claude process: #{inspect(entries)}"
      after
        AdapterBridge.close(bridge)
      end
    end
  end

  defp start_live_thread(state, thread_id, cwd) do
    msg = %{"method" => "session/new", "id" => 90, "params" => %{"cwd" => cwd}}
    assert {:ok, data, state} = Codex.translate_outbound(msg, state)

    native_id =
      data
      |> IO.iodata_to_binary()
      |> String.trim()
      |> Jason.decode!()
      |> Map.fetch!("id")

    assert {:messages, [%{"id" => 90}], state} =
             Codex.translate_inbound(
               Jason.encode!(%{
                 "id" => native_id,
                 "result" => %{"thread" => %{"id" => thread_id, "cwd" => cwd}}
               }),
               state
             )

    state
  end

  defp send_request(bridge, id, method, params) do
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(message))
  end

  defp receive_response(bridge, id) do
    case AdapterBridge.receive_message(bridge, 2_000) do
      {:ok, raw} ->
        message = Jason.decode!(raw)

        if message["id"] == id and not Map.has_key?(message, "method") do
          message
        else
          receive_response(bridge, id)
        end

      {:error, reason} ->
        flunk("expected a response for #{id}, got #{inspect(reason)}")
    end
  end

  defp read_pid_cwd_entries(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          [pid, cwd] = String.split(line, " ", parts: 2)
          {pid, cwd}
        end)

      {:error, :enoent} ->
        []
    end
  end

  defp session_pids(entries, cwd) do
    for {pid, entry_cwd} <- entries, paths_equivalent?(entry_cwd, cwd), do: pid
  end

  defp paths_equivalent?(left, right) do
    Path.expand(left) == Path.expand(right)
  end
end
