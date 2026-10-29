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
  alias Arbor.ACP.AdapterSupport.WorkspacePath
  alias Arbor.ACP.Adapters.ClaudeSDK
  alias Arbor.ACP.Adapters.ClaudeSDK.SessionStore
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

  describe "Claude bypass child" do
    test "a session opt-out of bypassPermissions constrains the Claude child", %{root: root} do
      workspace = Path.join(root, "ws")
      File.mkdir_p!(workspace)
      {cli, argv_log} = write_logging_cli(root)

      {:ok, state} =
        ClaudeSDK.init(
          cli_path: cli,
          cwd: workspace,
          workspace_roots: [workspace],
          permission_mode: :bypass,
          allow_dangerously_skip_permissions: true,
          claude_config_dir: Path.join(root, "claude")
        )

      msg = %{
        "id" => 1,
        "method" => "session/new",
        "params" => %{
          "cwd" => workspace,
          "sessionId" => "session-safe",
          "_meta" => %{
            "claudeCode" => %{"options" => %{"allowDangerouslySkipPermissions" => false}}
          }
        }
      }

      assert {:reply, result, state} = ClaudeSDK.translate_outbound(msg, state)
      assert state.bypass_allowed? == false
      refute result["modes"]["availableModes"] |> Enum.any?(&(&1["id"] == "bypassPermissions"))

      wait_until(fn -> File.exists?(argv_log) end)
      argv = File.read!(argv_log)

      refute argv =~ "bypassPermissions",
             "opted-out session spawned a bypass child: #{argv}"

      refute argv =~ "allow-dangerously-skip-permissions"
    end
  end

  describe "Claude cwd resolution" do
    test "session-store calls use the resolved cwd, not a lexical .. escape", %{root: root} do
      workspace = Path.join(root, "ws")
      outside = Path.join(root, "outside")
      child = Path.join(workspace, "child")
      File.mkdir_p!(workspace)
      File.mkdir_p!(outside)
      File.mkdir_p!(child)
      File.ln_s!(child, Path.join(outside, "link"))

      config_dir = Path.join(root, "claude")
      session_id = "123e4567-e89b-12d3-a456-426614174000"
      write_transcript!(config_dir, outside, session_id, "secret outside")

      {:ok, state} =
        ClaudeSDK.init(
          cwd: workspace,
          workspace_roots: [workspace],
          claude_config_dir: config_dir,
          managed: false
        )

      escaped = Path.join([outside, "link", ".."])

      assert {:ok, sessions, _state} = ClaudeSDK.list_sessions(%{"cwd" => escaped}, state)

      refute Enum.any?(sessions, &(&1["sessionId"] == session_id)),
             "list_sessions used the raw cwd and found an outside transcript: #{inspect(sessions)}"

      delete = %{
        "id" => 1,
        "method" => "session/delete",
        "params" => %{"sessionId" => session_id, "cwd" => escaped}
      }

      _ = ClaudeSDK.translate_outbound(delete, state)

      assert File.exists?(transcript_path(config_dir, outside, session_id)),
             "session/delete removed an outside transcript via a lexical cwd escape"
    end
  end

  describe "Claude unknown session ids" do
    test "a prompt with a forged sessionId is rejected and does not reach the active session",
         %{root: root} do
      workspace = Path.join(root, "ws")
      File.mkdir_p!(workspace)
      {cli, _argv_log, stdin_log} = write_logging_cli(root, stdin: true)

      {:ok, state} =
        ClaudeSDK.init(
          cli_path: cli,
          cwd: workspace,
          workspace_roots: [workspace],
          claude_config_dir: Path.join(root, "claude")
        )

      {:reply, _, state} =
        ClaudeSDK.translate_outbound(
          %{
            "id" => 1,
            "method" => "session/new",
            "params" => %{"cwd" => workspace, "sessionId" => "session-a"}
          },
          state
        )

      forged = %{
        "id" => 2,
        "method" => "session/prompt",
        "params" => %{
          "sessionId" => "forged-session",
          "prompt" => [%{"type" => "text", "text" => "cross-session"}]
        }
      }

      assert {:error, reason, _state} = ClaudeSDK.translate_outbound(forged, state)
      assert reason =~ ~r/unknown|not bound|session/i

      stdin = File.exists?(stdin_log) && File.read!(stdin_log) || ""
      refute stdin =~ "cross-session"
    end
  end

  describe "Claude fork process" do
    test "session/fork starts a process for the forked session", %{root: root} do
      workspace = Path.join(root, "ws")
      File.mkdir_p!(workspace)
      {cli, _argv_log} = write_logging_cli(root)
      config_dir = Path.join(root, "claude")
      parent_id = "123e4567-e89b-12d3-a456-426614174000"
      write_transcript!(config_dir, workspace, parent_id, "fork me")

      {:ok, state} =
        ClaudeSDK.init(
          cli_path: cli,
          cwd: workspace,
          workspace_roots: [workspace],
          claude_config_dir: config_dir
        )

      {:messages_and_reply, _, _, state} =
        ClaudeSDK.translate_outbound(
          %{
            "id" => 1,
            "method" => "session/load",
            "params" => %{"sessionId" => parent_id, "cwd" => workspace}
          },
          state
        )

      assert {:ok, result, state} =
               ClaudeSDK.fork_session(%{"sessionId" => parent_id, "cwd" => workspace}, state)

      forked_id = result["sessionId"]
      assert is_binary(forked_id)
      assert Map.has_key?(state.session_processes, forked_id)

      parent_handle = get_in(state.session_processes, [parent_id, :handle])
      forked_handle = get_in(state.session_processes, [forked_id, :handle])
      assert parent_handle
      assert forked_handle
      assert parent_handle != forked_handle
    end
  end

  describe "Claude client responses" do
    test "a client response is routed to the session that issued the request", %{root: root} do
      workspace = Path.join(root, "ws")
      File.mkdir_p!(workspace)
      {cli, _argv_log} = write_logging_cli(root)

      {:ok, state} =
        ClaudeSDK.init(
          cli_path: cli,
          cwd: workspace,
          workspace_roots: [workspace],
          claude_config_dir: Path.join(root, "claude")
        )

      {:reply, _, state} =
        ClaudeSDK.translate_outbound(
          %{
            "id" => 1,
            "method" => "session/new",
            "params" => %{"cwd" => workspace, "sessionId" => "session-a"}
          },
          state
        )

      {:reply, _, state} =
        ClaudeSDK.translate_outbound(
          %{
            "id" => 2,
            "method" => "session/new",
            "params" => %{"cwd" => workspace, "sessionId" => "session-b"}
          },
          state
        )

      state = put_pending_on_session(state, "session-a", "acp-file", "ctrl-file-1")

      result =
        ClaudeSDK.translate_outbound(
          %{"id" => "acp-file", "result" => %{"content" => []}},
          state
        )

      state = elem(result, tuple_size(result) - 1)
      pending = get_in(state.session_processes, ["session-a", :fields, :pending_client_requests])

      assert pending == %{},
             "session A's pending client request was dropped while session B was current: #{inspect(pending)}"
    end
  end

  describe "Codex closed and forged threads" do
    test "a closed thread cannot be resumed from another workspace", %{root: root} do
      ws_a = Path.join(root, "ws-a")
      ws_b = Path.join(root, "ws-b")
      File.mkdir_p!(ws_a)
      File.mkdir_p!(ws_b)

      {:ok, state} = Codex.init(workspace_roots: [ws_a, ws_b], cwd: ws_a)
      state = start_live_thread(state, "thread-a", ws_a)

      assert {:messages_and_write, _, _, state} =
               Codex.translate_outbound(
                 %{"method" => "session/close", "params" => %{"sessionId" => "thread-a"}},
                 state
               )

      for {method, id} <- [{"session/load", "acp-load"}, {"session/resume", "acp-resume"}] do
        msg = %{
          "method" => method,
          "id" => id,
          "params" => %{"sessionId" => "thread-a", "cwd" => ws_b}
        }

        assert {:error, reason, _state} = Codex.translate_outbound(msg, state)

        assert reason =~ ~r/not bound|workspace|session|thread/i,
               "#{method} of a closed thread from another workspace, got: #{inspect(reason)}"
      end
    end

    test "a forged thread id cannot be reused from another workspace", %{root: root} do
      ws_a = Path.join(root, "ws-a")
      ws_b = Path.join(root, "ws-b")
      File.mkdir_p!(ws_a)
      File.mkdir_p!(ws_b)

      {:ok, state} = Codex.init(workspace_roots: [ws_a, ws_b], cwd: ws_a)

      claim = %{
        "method" => "session/load",
        "id" => "acp-claim",
        "params" => %{"sessionId" => "thread-forged", "cwd" => ws_a}
      }

      assert {:ok, _data, state} = Codex.translate_outbound(claim, state)

      steal = %{
        "method" => "session/resume",
        "id" => "acp-steal",
        "params" => %{"sessionId" => "thread-forged", "cwd" => ws_b}
      }

      assert {:error, reason, _state} = Codex.translate_outbound(steal, state)
      assert reason =~ ~r/not bound|workspace|session|thread/i
    end
  end

  describe "Claude workspace authorization" do
    test "authorize_workspace treats error tuples as denied", %{root: root} do
      workspace = Path.join(root, "ws")
      File.mkdir_p!(workspace)

      for callback <- [
            fn _path, _ctx -> {:error, :denied} end,
            fn _path -> :error end
          ] do
        {:ok, state} =
          ClaudeSDK.init(
            cwd: workspace,
            authorize_workspace: callback,
            claude_config_dir: Path.join(root, "claude"),
            managed: false
          )

        msg = %{
          "id" => 1,
          "method" => "session/new",
          "params" => %{"cwd" => workspace}
        }

        assert {:error, reason, _state} = ClaudeSDK.translate_outbound(msg, state)

        assert reason =~ ~r/not authorized|workspace/i,
               "callback #{inspect(callback)} was treated as allow, got: #{inspect(reason)}"
      end
    end

    test "the implicit workspace root is the adapter cwd, not the current session cwd",
         %{root: root} do
      ws_a = Path.join(root, "ws-a")
      ws_b = Path.join(root, "ws-b")
      File.mkdir_p!(ws_a)
      File.mkdir_p!(ws_b)

      {:ok, state} =
        ClaudeSDK.init(cwd: root, claude_config_dir: Path.join(root, "claude"), managed: false)

      {:reply, _, state} =
        ClaudeSDK.translate_outbound(
          %{"id" => 1, "method" => "session/new", "params" => %{"cwd" => ws_a}},
          state
        )

      sibling = %{
        "id" => 2,
        "method" => "session/new",
        "params" => %{"cwd" => ws_b}
      }

      assert {:reply, result, _state} = ClaudeSDK.translate_outbound(sibling, state)
      assert is_binary(result["sessionId"])
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
    WorkspacePath.canonical(left) == WorkspacePath.canonical(right)
  end

  defp write_logging_cli(root, opts \\ []) do
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    cli = Path.join(bin, "claude")
    argv_log = Path.join(root, "argv.log")
    stdin_log = Path.join(root, "stdin.log")

    stdin_bit =
      if Keyword.get(opts, :stdin, false) do
        "printf '%s\\n' \"$_line\" >> \"#{stdin_log}\"\n"
      else
        ""
      end

    File.write!(cli, """
    #!/bin/sh
    printf '%s\\n' "$*" >> "#{argv_log}"
    printf '%s %s\\n' "$$" "$(pwd)" >> "#{Path.join(root, "pids.log")}"
    while IFS= read -r _line; do
    #{stdin_bit}  :
    done
    """)

    File.chmod!(cli, 0o755)

    if Keyword.get(opts, :stdin, false) do
      {cli, argv_log, stdin_log}
    else
      {cli, argv_log}
    end
  end

  defp write_transcript!(config_dir, cwd, session_id, summary) do
    project_dir =
      config_dir
      |> Path.join("projects")
      |> Path.join(SessionStore.project_key(cwd))

    File.mkdir_p!(project_dir)

    File.write!(transcript_path(config_dir, cwd, session_id), """
    #{Jason.encode!(%{"type" => "summary", "summary" => summary, "cwd" => cwd, "sessionId" => session_id})}
    """)
  end

  defp transcript_path(config_dir, cwd, session_id) do
    config_dir
    |> Path.join("projects")
    |> Path.join(SessionStore.project_key(cwd))
    |> Path.join("#{session_id}.jsonl")
  end

  defp put_pending_on_session(state, session_id, acp_id, request_id) do
    case Map.get(state.session_processes, session_id) do
      nil ->
        flunk("expected session #{session_id} to have a process")

      entry ->
        fields =
          Map.update(entry.fields, :pending_client_requests, %{}, fn pending ->
            Map.put(pending, acp_id, %{
              request_id: request_id,
              kind: :file_read,
              request: %{}
            })
          end)

        %{
          state
          | session_processes: Map.put(state.session_processes, session_id, %{entry | fields: fields})
        }
    end
  end
end
