defmodule Arbor.ACP.Adapters.PiTest do
  use ExUnit.Case, async: true

  alias Arbor.ACP.Adapters.Pi
  alias Arbor.ACP.Adapters.Pi.Settings
  alias Arbor.ACP.Adapters.Pi.SlashCommands
  alias Arbor.ACP.Adapters.Internal.PromptQueue
  alias Arbor.ACP.AdapterSupport.Subprocess, as: PortRunner

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "pi_test_#{System.unique_integer([:positive])}")
    session_dir = Path.join(tmp_dir, "sessions")
    session_map_path = Path.join(tmp_dir, "session-map.json")

    File.mkdir_p!(session_dir)

    {:ok, state} =
      Pi.init(
        cwd: tmp_dir,
        session_dir: session_dir,
        session_map_path: session_map_path,
        managed: false
      )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{
      state: state,
      tmp_dir: tmp_dir,
      session_dir: session_dir,
      session_map_path: session_map_path
    }
  end

  describe "command/1" do
    test "uses adapter-managed bridge mode" do
      assert Pi.command([]) == :adapter_managed
    end

    test "returns pi cli command with rpc mode" do
      {cmd, args} = Pi.cli_command([])
      assert cmd == "pi"
      assert "--mode" in args
      assert "rpc" in args
      assert "--no-themes" in args
    end

    test "includes session path" do
      {_cmd, args} = Pi.cli_command(session_path: "/tmp/session.jsonl")
      assert "--session" in args
      assert "/tmp/session.jsonl" in args
    end

    test "rejects a session_path that would be parsed as another flag" do
      for session_path <- ["-x", ~c"--mode"] do
        assert {:error, {:invalid_option, :session_path, "must not start with '-'"}} =
                 Pi.cli_command(session_path: session_path)
      end
    end

    test "does not pass unsupported runtime settings through process argv" do
      {_cmd, args} =
        Pi.cli_command(
          model: "anthropic/claude-sonnet-4",
          cwd: "/tmp/project",
          session_dir: "/tmp/pi-sessions",
          system_prompt: "custom prompt",
          no_session: true
        )

      refute "--model" in args
      refute "anthropic/claude-sonnet-4" in args
      refute "--cwd" in args
      refute "/tmp/project" in args
      refute "--session-dir" in args
      refute "/tmp/pi-sessions" in args
      refute "--system-prompt" in args
      refute "custom prompt" in args
      refute "--no-session" in args
    end

    test "does not pass api key through process argv" do
      {_cmd, args} = Pi.cli_command(api_key: "secret")
      refute "--api-key" in args
      refute "secret" in args
    end
  end

  describe "isolated configuration" do
    test "loads global settings and prompts from an explicit agent directory", %{tmp_dir: tmp_dir} do
      agent_dir = Path.join(tmp_dir, "agent")
      prompts_dir = Path.join(agent_dir, "prompts")
      File.mkdir_p!(prompts_dir)
      File.write!(Path.join(agent_dir, "settings.json"), Jason.encode!(%{"quietStartup" => true}))
      File.write!(Path.join(prompts_dir, "review.md"), "Review this change")

      settings = Settings.load(tmp_dir, agent_dir: agent_dir)
      commands = SlashCommands.load(tmp_dir, agent_dir: agent_dir)

      assert settings["quietStartup"] == true
      assert settings["_agentDir"] == agent_dir
      assert Enum.any?(commands, &(&1["name"] == "review" and &1["source"] =~ "user"))
    end

    test "normalizes command input strings to ACP input hints" do
      commands = SlashCommands.available_commands([])

      assert Enum.find(commands, &(&1["name"] == "compact"))["input"] == %{
               "hint" => "optional instructions"
             }

      assert Enum.find(commands, &(&1["name"] == "autocompact"))["input"] == %{
               "hint" => "on | off"
             }

      assert SlashCommands.normalize_input(%{
               "name" => "custom",
               "input" => %{"hint" => "value", "unsupported" => true}
             }) == %{"name" => "custom", "input" => %{"hint" => "value"}}

      refute Map.has_key?(SlashCommands.normalize_input(%{"input" => ["invalid"]}), "input")
    end

    test "project settings cannot choose the executable", %{tmp_dir: tmp_dir} do
      agent_dir = Path.join(tmp_dir, "agent")
      project = Path.join(tmp_dir, "project")
      File.mkdir_p!(agent_dir)
      File.mkdir_p!(Path.join(project, ".pi"))

      File.write!(
        Path.join(project, ".pi/settings.json"),
        Jason.encode!(%{"piCommand" => "./evil", "quietStartup" => true})
      )

      settings = Settings.load(project, agent_dir: agent_dir)
      assert settings["quietStartup"] == true
      refute Map.has_key?(settings, "piCommand")
      assert Settings.pi_command([agent_dir: agent_dir], settings) == "pi"
      assert {"pi", _args} = Pi.cli_command(cwd: project, agent_dir: agent_dir)

      File.write!(
        Path.join(agent_dir, "settings.json"),
        Jason.encode!(%{"piCommand" => "/opt/pi"})
      )

      settings = Settings.load(project, agent_dir: agent_dir)
      assert Settings.pi_command([agent_dir: agent_dir], settings) == "/opt/pi"

      assert Settings.pi_command([agent_dir: agent_dir, cli_path: "/usr/bin/pi"], settings) ==
               "/usr/bin/pi"
    end
  end

  describe "capabilities/0" do
    test "returns ACP-native capabilities and adapter metadata" do
      caps = Pi.capabilities()
      pi_meta = caps["_meta"]["ex_mcp"]["pi"]

      assert caps["loadSession"] == true
      assert caps["promptCapabilities"]["image"] == true
      assert caps["promptCapabilities"]["audio"] == false
      assert caps["mcpCapabilities"] == %{"http" => false, "sse" => false}
      assert caps["sessionCapabilities"]["list"] == %{}
      assert caps["sessionCapabilities"]["resume"] == %{}
      assert caps["sessionCapabilities"]["close"] == %{}
      assert caps["sessionCapabilities"]["delete"] == %{}
      refute Map.has_key?(pi_meta, "methods")
      assert pi_meta["features"]["slashCommands"] == true
      assert pi_meta["features"]["terminalAuth"] == true
      assert pi_meta["features"]["modelSelection"] == true
    end
  end

  describe "auth_methods/1" do
    test "advertises terminal login" do
      assert [%{"id" => "pi_terminal_login", "type" => "terminal"} = auth] =
               Pi.auth_methods(cli_path: "/bin/pi")

      assert auth["_meta"]["terminal-auth"]["command"] == "/bin/pi"
    end
  end

  describe "modes/0" do
    test "returns Pi thinking levels as ACP modes" do
      ids = Pi.modes() |> Enum.map(& &1["id"])
      assert ids == ["off", "minimal", "low", "medium", "high", "xhigh"]
    end
  end

  test "Pi session rename events update the ACP session title", %{state: state} do
    state = %{state | session_id: "s1"}

    assert {:messages, [update], ^state} =
             Pi.translate_inbound(
               Jason.encode!(%{"type" => "session_info_changed", "name" => "  New title  "}),
               state
             )

    assert update["params"]["sessionId"] == "s1"
    assert update["params"]["update"]["title"] == "New title"
    assert update["params"]["update"]["sessionUpdate"] == "session_info_update"
  end

  test "a cleared Pi session name clears the ACP session title", %{state: state} do
    state = %{state | session_id: "s1"}

    # Pi serializes an unset name as a missing key; null is accepted as well.
    for event <- [
          %{"type" => "session_info_changed"},
          %{"type" => "session_info_changed", "name" => nil}
        ] do
      assert {:messages, [update], ^state} = Pi.translate_inbound(Jason.encode!(event), state)
      assert update["params"]["sessionId"] == "s1"
      assert update["params"]["update"]["sessionUpdate"] == "session_info_update"
      assert Map.fetch!(update["params"]["update"], "title") == nil
      assert is_binary(update["params"]["update"]["updatedAt"])
    end

    assert {:skip, ^state} =
             Pi.translate_inbound(
               Jason.encode!(%{"type" => "session_info_changed", "name" => 42}),
               state
             )
  end

  describe "config_options/0" do
    test "returns Pi static runtime config options and the thinking selector" do
      ids = Pi.config_options() |> Enum.map(& &1["id"])

      assert "thought_level" in ids
      assert "auto_compaction" in ids
      assert "auto_retry" in ids
      assert "steering_mode" in ids
      assert "follow_up_mode" in ids
      refute "model" in ids
    end
  end

  describe "list_sessions/2" do
    test "returns empty list when session dir doesn't exist", %{state: state} do
      state = %{state | session_dir: "/nonexistent/path"}
      assert {:ok, %{"sessions" => [], "_meta" => %{}}, _state} = Pi.list_sessions(%{}, state)
    end

    test "scans Pi jsonl session files and omits private file paths", %{
      state: state,
      session_dir: session_dir,
      tmp_dir: tmp_dir
    } do
      write_session(session_dir, "s1", tmp_dir, "First prompt", "Project session")
      write_session(session_dir, "s2", "/other/project", "Other prompt", nil)

      state = %{state | last_session_cwd: nil}

      assert {:ok, %{"sessions" => sessions}, _state} = Pi.list_sessions(%{}, state)

      assert Enum.map(sessions, & &1["sessionId"]) |> Enum.sort() == ["s1", "s2"]
      assert Enum.all?(sessions, &(not Map.has_key?(&1, "sessionFile")))
      assert Enum.any?(sessions, &(&1["title"] == "Project session"))
    end

    test "filters by cwd", %{state: state, session_dir: session_dir, tmp_dir: tmp_dir} do
      write_session(session_dir, "s1", tmp_dir, "First prompt", nil)
      write_session(session_dir, "s2", "/other/project", "Other prompt", nil)

      assert {:ok, %{"sessions" => [%{"sessionId" => "s1"}]}, _state} =
               Pi.list_sessions(%{"cwd" => tmp_dir}, state)
    end

    test "defaults empty list requests to last session cwd", %{
      state: state,
      session_dir: session_dir,
      tmp_dir: tmp_dir
    } do
      write_session(session_dir, "s1", tmp_dir, "First prompt", nil)
      write_session(session_dir, "s2", "/other/project", "Other prompt", nil)

      state = %{state | last_session_cwd: tmp_dir}

      assert {:ok, %{"sessions" => [%{"sessionId" => "s1"}]}, _state} =
               Pi.list_sessions(%{}, state)
    end

    test "uses latest message timestamp instead of later metadata timestamp", %{
      state: state,
      session_dir: session_dir,
      tmp_dir: tmp_dir
    } do
      write_session(session_dir, "s1", tmp_dir, "First prompt", "Renamed session")

      assert {:ok, %{"sessions" => [%{"sessionId" => "s1"} = session]}, _state} =
               Pi.list_sessions(%{"cwd" => tmp_dir}, state)

      assert session["updatedAt"] == "2026-01-01T00:00:01Z"
    end
  end

  describe "translate_outbound/2 — session lifecycle" do
    # The golden harness normalizes minted ids by first appearance in the
    # transcript, so it cannot see a change in the order the ids are minted as
    # long as the emission order holds. These assert the raw numbers: the rpc
    # counter is shared with control-group ids, so a refactor that binds the
    # requests in a different order silently renumbers the wire.
    test "session/load mints correlation ids in emission order", %{
      state: state,
      tmp_dir: tmp_dir,
      session_dir: session_dir,
      session_map_path: session_map_path
    } do
      session_file = Path.join(session_dir, "s1.jsonl")
      File.write!(session_file, "")

      File.write!(
        session_map_path,
        Jason.encode!(%{
          "version" => 1,
          "sessions" => %{
            "s1" => %{"sessionId" => "s1", "cwd" => tmp_dir, "sessionFile" => session_file}
          }
        })
      )

      msg = %{"method" => "session/load", "id" => 1, "params" => %{"sessionId" => "s1"}}

      assert {:ok, data, state} = Pi.translate_outbound(msg, state)
      {requests, _state} = confirm_session_change(data, state)

      assert Enum.map(requests, & &1["type"]) == [
               "switch_session",
               "get_messages",
               "get_state",
               "get_available_models",
               "get_available_thinking_levels",
               "get_commands"
             ]

      assert ascending_rpc_ids(requests)
    end

    test "session/resume mints correlation ids in emission order and skips replay", %{
      state: state,
      tmp_dir: tmp_dir,
      session_dir: session_dir,
      session_map_path: session_map_path
    } do
      session_file = Path.join(session_dir, "s1.jsonl")
      File.write!(session_file, "")

      File.write!(
        session_map_path,
        Jason.encode!(%{
          "version" => 1,
          "sessions" => %{
            "s1" => %{"sessionId" => "s1", "cwd" => tmp_dir, "sessionFile" => session_file}
          }
        })
      )

      msg = %{"method" => "session/resume", "id" => 1, "params" => %{"sessionId" => "s1"}}

      assert {:ok, data, state} = Pi.translate_outbound(msg, state)
      {requests, _state} = confirm_session_change(data, state)

      assert Enum.map(requests, & &1["type"]) == [
               "switch_session",
               "get_state",
               "get_available_models",
               "get_available_thinking_levels",
               "get_commands"
             ]

      assert ascending_rpc_ids(requests)
    end

    test "session/new sends Pi control requests and completes from correlated responses", %{
      state: state,
      tmp_dir: tmp_dir
    } do
      msg = %{"method" => "session/new", "id" => 11, "params" => %{"cwd" => tmp_dir}}

      assert {:ok, data, state} = Pi.translate_outbound(msg, state)
      {requests, state} = confirm_session_change(data, state)

      assert Enum.map(requests, & &1["type"]) == [
               "new_session",
               "get_state",
               "get_available_models",
               "get_available_thinking_levels",
               "get_commands"
             ]

      ids_by_type = Map.new(requests, &{&1["type"], &1["id"]})

      state =
        state
        |> respond(ids_by_type["get_state"], "get_state", %{
          "sessionId" => "pi-session",
          "sessionFile" => Path.join(tmp_dir, "pi-session.jsonl"),
          "cwd" => tmp_dir,
          "thinkingLevel" => "high",
          "model" => %{"provider" => "anthropic", "id" => "claude-sonnet-4"}
        })
        |> respond(ids_by_type["get_available_models"], "get_available_models", %{
          "models" => [
            %{"provider" => "anthropic", "id" => "claude-sonnet-4", "name" => "Claude Sonnet 4"}
          ]
        })
        |> respond(
          ids_by_type["get_available_thinking_levels"],
          "get_available_thinking_levels",
          %{
            "levels" => ["off", "low", "medium", "high"]
          }
        )

      assert {:messages, [response, commands_update], state} =
               Pi.translate_inbound(
                 response_line(ids_by_type["get_commands"], "get_commands", %{
                   "commands" => [
                     %{
                       "name" => "model",
                       "description" => "Model picker",
                       "source" => "extension"
                     }
                   ]
                 }),
                 state
               )

      assert response["id"] == 11
      assert response["result"]["sessionId"] == "pi-session"
      assert response["result"]["modes"]["currentModeId"] == "high"

      assert Enum.map(response["result"]["modes"]["availableModes"], & &1["id"]) == [
               "off",
               "low",
               "medium",
               "high"
             ]

      assert response["result"]["models"]["currentModelId"] == "anthropic/claude-sonnet-4"

      assert Enum.map(response["result"]["configOptions"], & &1["id"]) == [
               "model",
               "thought_level",
               "auto_compaction",
               "auto_retry",
               "steering_mode",
               "follow_up_mode"
             ]

      assert Enum.find(response["result"]["configOptions"], &(&1["id"] == "model"))[
               "currentValue"
             ] == "anthropic/claude-sonnet-4"

      assert Enum.find(response["result"]["configOptions"], &(&1["id"] == "thought_level"))[
               "currentValue"
             ] == "high"

      assert commands_update["params"]["update"]["sessionUpdate"] == "available_commands_update"
      assert state.session_id == "pi-session"
      assert state.available_thinking_levels == ["off", "low", "medium", "high"]

      assert {:error, "Unknown modeId: \"xhigh\"", ^state} =
               Pi.translate_outbound(
                 %{
                   "method" => "session/set_mode",
                   "params" => %{"sessionId" => "pi-session", "modeId" => "xhigh"}
                 },
                 state
               )

      assert state.available_models == [
               %{
                 "modelId" => "anthropic/claude-sonnet-4",
                 "name" => "anthropic/Claude Sonnet 4",
                 "description" => nil
               }
             ]
    end

    test "Pi 0.80.x rejecting get_available_thinking_levels falls back to the static levels", %{
      state: state,
      tmp_dir: tmp_dir,
      session_dir: session_dir,
      session_map_path: session_map_path
    } do
      session_file = Path.join(session_dir, "s1.jsonl")
      File.write!(session_file, "")

      File.write!(
        session_map_path,
        Jason.encode!(%{
          "version" => 1,
          "sessions" => %{
            "s1" => %{"sessionId" => "s1", "cwd" => tmp_dir, "sessionFile" => session_file}
          }
        })
      )

      for {method, params, extra} <- [
            {"session/new", %{"cwd" => tmp_dir}, %{"new_session" => %{}}},
            {"session/load", %{"sessionId" => "s1", "cwd" => tmp_dir},
             %{"switch_session" => %{}, "get_messages" => %{"messages" => []}}}
          ] do
        msg = %{"method" => method, "id" => 21, "params" => params}
        assert {:ok, data, state} = Pi.translate_outbound(msg, state)
        {requests, state} = confirm_session_change(data, state)
        ids_by_type = Map.new(requests, &{&1["type"], &1["id"]})

        # Pi before 0.81.0 answers the command it does not know with this reply.
        assert {:skip, state} =
                 Pi.translate_inbound(
                   Jason.encode!(%{
                     "type" => "response",
                     "id" => ids_by_type["get_available_thinking_levels"],
                     "command" => "get_available_thinking_levels",
                     "success" => false,
                     "error" => "Unknown command: get_available_thinking_levels"
                   }),
                   state
                 )

        state =
          Enum.reduce(extra, state, fn {type, data}, state ->
            respond(state, ids_by_type[type], type, data)
          end)
          |> respond(ids_by_type["get_state"], "get_state", %{
            "sessionId" => "s1",
            "sessionFile" => session_file,
            "cwd" => tmp_dir,
            "thinkingLevel" => "xhigh",
            "model" => %{"provider" => "openai", "id" => "gpt-5.1"}
          })
          |> respond(ids_by_type["get_available_models"], "get_available_models", %{
            "models" => [%{"provider" => "openai", "id" => "gpt-5.1"}]
          })

        assert {:messages, messages, state} =
                 Pi.translate_inbound(
                   response_line(ids_by_type["get_commands"], "get_commands", %{"commands" => []}),
                   state
                 )

        assert %{"result" => result} = Enum.find(messages, &(&1["id"] == 21))
        refute Enum.any?(messages, &Map.has_key?(&1, "error"))
        assert result["sessionId"] == "s1"
        assert result["modes"]["currentModeId"] == "xhigh"

        assert Enum.map(result["modes"]["availableModes"], & &1["id"]) ==
                 ~w(off minimal low medium high xhigh)

        assert state.available_thinking_levels == ~w(off minimal low medium high xhigh)
        assert map_size(state.control_groups) == 0
        assert map_size(state.pending_controls) == 0
      end
    end

    test "session/new keeps the host cwd when the agent reports another", %{
      state: state,
      tmp_dir: tmp_dir
    } do
      msg = %{"method" => "session/new", "id" => 13, "params" => %{"cwd" => tmp_dir}}

      assert {:ok, data, state} = Pi.translate_outbound(msg, state)
      {requests, state} = confirm_session_change(data, state)
      ids_by_type = Map.new(requests, &{&1["type"], &1["id"]})

      state =
        state
        |> respond(ids_by_type["get_state"], "get_state", %{
          "sessionId" => "pi-session",
          "sessionFile" => Path.join(tmp_dir, "pi-session.jsonl"),
          "cwd" => "/"
        })
        |> respond(ids_by_type["get_available_models"], "get_available_models", %{
          "models" => []
        })
        |> respond(
          ids_by_type["get_available_thinking_levels"],
          "get_available_thinking_levels",
          %{
            "levels" => ["off", "medium"]
          }
        )

      assert {:messages, [response | _], state} =
               Pi.translate_inbound(
                 response_line(ids_by_type["get_commands"], "get_commands", %{"commands" => []}),
                 state
               )

      assert response["id"] == 13
      assert state.workspace_root == tmp_dir
    end

    test "session/load without cwd falls back to the host root, not the agent-reported cwd", %{
      state: state,
      tmp_dir: tmp_dir,
      session_dir: session_dir,
      session_map_path: session_map_path
    } do
      session_file = Path.join(session_dir, "s1.jsonl")
      File.write!(session_file, "")

      File.write!(
        session_map_path,
        Jason.encode!(%{
          "version" => 1,
          "sessions" => %{
            "s1" => %{"sessionId" => "s1", "cwd" => tmp_dir, "sessionFile" => session_file}
          }
        })
      )

      # State after an established session whose agent reported `cwd: "/"`.
      state = %{state | cwd: "/", workspace_root: tmp_dir, last_session_cwd: "/"}
      msg = %{"method" => "session/load", "id" => 1, "params" => %{"sessionId" => "s1"}}

      assert {:ok, _data, state} = Pi.translate_outbound(msg, state)
      assert state.workspace_root == tmp_dir
    end

    test "session/new maps empty model list to auth-required", %{state: state, tmp_dir: tmp_dir} do
      msg = %{"method" => "session/new", "id" => 12, "params" => %{"cwd" => tmp_dir}}

      assert {:ok, data, state} = Pi.translate_outbound(msg, state)
      {requests, state} = confirm_session_change(data, state)
      ids_by_type = Map.new(requests, &{&1["type"], &1["id"]})

      state =
        state
        |> respond(ids_by_type["get_state"], "get_state", %{
          "sessionId" => "pi-session",
          "cwd" => tmp_dir
        })
        |> respond(ids_by_type["get_commands"], "get_commands", %{"commands" => []})
        |> respond(
          ids_by_type["get_available_thinking_levels"],
          "get_available_thinking_levels",
          %{
            "levels" => ["off", "medium"]
          }
        )

      assert {:messages, [error], _state} =
               Pi.translate_inbound(
                 response_line(ids_by_type["get_available_models"], "get_available_models", %{
                   "models" => []
                 }),
                 state
               )

      assert error["id"] == 12
      assert error["error"]["data"]["authMethods"] != []
    end

    test "session/load uses the local session map and replays messages", %{
      state: state,
      tmp_dir: tmp_dir,
      session_map_path: session_map_path
    } do
      session_file = Path.join(tmp_dir, "mapped.jsonl")

      File.write!(
        session_map_path,
        Jason.encode!(%{
          "version" => 1,
          "sessions" => %{
            "mapped-session" => %{
              "sessionId" => "mapped-session",
              "cwd" => tmp_dir,
              "sessionFile" => session_file
            }
          }
        })
      )

      msg = %{
        "method" => "session/load",
        "id" => 13,
        "params" => %{"sessionId" => "mapped-session", "cwd" => tmp_dir}
      }

      assert {:ok, data, state} = Pi.translate_outbound(msg, state)
      {requests, state} = confirm_session_change(data, state)
      assert Enum.find(requests, &(&1["type"] == "switch_session"))["sessionPath"] == session_file
      ids_by_type = Map.new(requests, &{&1["type"], &1["id"]})

      state =
        state
        |> respond(ids_by_type["get_state"], "get_state", %{
          "sessionId" => "mapped-session",
          "cwd" => tmp_dir
        })
        |> respond(ids_by_type["get_available_models"], "get_available_models", %{
          "models" => [%{"provider" => "openai", "id" => "gpt-5.1"}]
        })
        |> respond(ids_by_type["get_commands"], "get_commands", %{"commands" => []})
        |> respond(
          ids_by_type["get_available_thinking_levels"],
          "get_available_thinking_levels",
          %{
            "levels" => ["off", "medium"]
          }
        )

      assert {:messages, messages, _state} =
               Pi.translate_inbound(
                 response_line(ids_by_type["get_messages"], "get_messages", %{
                   "messages" => [
                     %{"role" => "user", "content" => "Hello"},
                     %{"role" => "assistant", "content" => "Hi"}
                   ]
                 }),
                 state
               )

      assert Enum.any?(
               messages,
               &(get_in(&1, ["params", "update", "sessionUpdate"]) == "user_message_chunk")
             )

      assert Enum.any?(messages, &(&1["id"] == 13))
    end

    test "session/resume loads session state without replaying messages", %{
      state: state,
      tmp_dir: tmp_dir,
      session_map_path: session_map_path
    } do
      session_file = Path.join(tmp_dir, "mapped.jsonl")

      File.write!(
        session_map_path,
        Jason.encode!(%{
          "version" => 1,
          "sessions" => %{
            "mapped-session" => %{
              "sessionId" => "mapped-session",
              "cwd" => tmp_dir,
              "sessionFile" => session_file
            }
          }
        })
      )

      msg = %{
        "method" => "session/resume",
        "id" => 14,
        "params" => %{"sessionId" => "mapped-session", "cwd" => tmp_dir}
      }

      assert {:ok, data, state} = Pi.translate_outbound(msg, state)
      {requests, state} = confirm_session_change(data, state)
      refute Enum.any?(requests, &(&1["type"] == "get_messages"))
      ids_by_type = Map.new(requests, &{&1["type"], &1["id"]})

      state =
        state
        |> respond(ids_by_type["get_state"], "get_state", %{
          "sessionId" => "mapped-session",
          "cwd" => tmp_dir
        })
        |> respond(ids_by_type["get_available_models"], "get_available_models", %{
          "models" => [%{"provider" => "openai", "id" => "gpt-5.1"}]
        })
        |> respond(
          ids_by_type["get_available_thinking_levels"],
          "get_available_thinking_levels",
          %{
            "levels" => ["off", "medium"]
          }
        )

      assert {:messages, messages, _state} =
               Pi.translate_inbound(
                 response_line(ids_by_type["get_commands"], "get_commands", %{"commands" => []}),
                 state
               )

      refute Enum.any?(
               messages,
               &(get_in(&1, ["params", "update", "sessionUpdate"]) == "user_message_chunk")
             )

      assert Enum.any?(messages, &(&1["id"] == 14))
    end

    test "session/close clears active runtime state", %{state: state} do
      state = %{
        state
        | session_id: "s1",
          pending_prompt: %{acp_id: 1, msg_id: "msg-1", cancel_requested: false},
          prompt_queue:
            PromptQueue.new()
            |> PromptQueue.enqueue(%{acp_id: 2, message: "queued", images: [], params: %{}})
      }

      assert {:reply, %{}, new_state} =
               Pi.translate_outbound(
                 %{"method" => "session/close", "params" => %{"sessionId" => "s1"}},
                 state
               )

      assert new_state.pending_prompt == nil
      assert PromptQueue.empty?(new_state.prompt_queue)
    end

    test "session/delete removes local map but leaves Pi session file by default", %{
      state: state,
      tmp_dir: tmp_dir,
      session_map_path: session_map_path
    } do
      session_file = Path.join(tmp_dir, "mapped.jsonl")
      File.write!(session_file, "")

      File.write!(
        session_map_path,
        Jason.encode!(%{
          "version" => 1,
          "sessions" => %{
            "mapped-session" => %{
              "sessionId" => "mapped-session",
              "cwd" => tmp_dir,
              "sessionFile" => session_file
            }
          }
        })
      )

      assert {:reply, %{}, _state} =
               Pi.translate_outbound(
                 %{"method" => "session/delete", "params" => %{"sessionId" => "mapped-session"}},
                 state
               )

      assert File.exists?(session_file)

      assert {:ok, %{"sessions" => []}, _state} =
               Pi.list_sessions(%{"cwd" => tmp_dir}, %{state | last_session_cwd: nil})
    end
  end

  describe "translate_outbound/2 — model, mode, and config" do
    test "a model switch refreshes only after Pi has switched the model", %{state: state} do
      state = switch_ready_state(state)
      pi = fake_pi()

      assert {:messages_and_write, [_optimistic], data, state} =
               Pi.translate_outbound(set_model_request("openai/gpt-5.1"), state)

      {state, _pi, messages} = drive_fake_pi(data, state, pi)

      # The refresh describes the new model, not the one Pi was leaving.
      assert state.available_thinking_levels == ["off", "minimal", "low"]
      assert state.thinking_level == "low"
      assert state.current_model_id == "openai/gpt-5.1"
      assert state.pending_model_switch == nil
      assert state.pending_model_refresh == nil

      # set_model goes alone, as a request whose reply starts the refresh.
      assert [%{"type" => "set_model", "id" => "pi-" <> _}] = decode_many(data)
      assert [mode_update, config_update] = messages
      assert mode_update["params"]["update"]["currentModeId"] == "low"
      options = config_update["params"]["update"]["configOptions"]
      thought = Enum.find(options, &(&1["id"] == "thought_level"))
      assert Enum.map(thought["options"], & &1["value"]) == ["off", "minimal", "low"]
      assert thought["currentValue"] == "low"
      assert Enum.find(options, &(&1["id"] == "model"))["currentValue"] == "openai/gpt-5.1"
    end

    test "the model config option refreshes after Pi switches too", %{state: state} do
      state = switch_ready_state(state)

      msg = %{
        "method" => "session/set_config_option",
        "params" => %{"sessionId" => "s1", "configId" => "model", "value" => "openai/gpt-5.1"}
      }

      assert {:messages_and_write, [_optimistic], data, state} = Pi.translate_outbound(msg, state)
      assert [%{"type" => "set_model", "id" => "pi-" <> _}] = decode_many(data)

      {state, _pi, [_mode_update, _config_update]} = drive_fake_pi(data, state, fake_pi())
      assert state.available_thinking_levels == ["off", "minimal", "low"]
      assert state.thinking_level == "low"
    end

    test "a set_mode sent after the refresh keeps its level", %{state: state} do
      state = switch_ready_state(state)
      pi = fake_pi()

      assert {:messages_and_write, _, data, state} =
               Pi.translate_outbound(set_model_request("openai/gpt-5.1"), state)

      {[level_event, switch_reply], pi} = fake_pi_answer(decode_many(data), pi)

      # The refresh that follows the switch publishes the switch's level.
      assert {:skip, state} = Pi.translate_inbound(Jason.encode!(level_event), state)

      assert {:skip_and_write, refresh, state} =
               Pi.translate_inbound(Jason.encode!(switch_reply), state)

      assert Enum.map(decode_many(refresh), & &1["type"]) == [
               "get_state",
               "get_available_thinking_levels"
             ]

      assert {:messages_and_write, _, set_level, state} =
               Pi.translate_outbound(
                 %{
                   "method" => "session/set_mode",
                   "params" => %{"sessionId" => "s1", "modeId" => "off"}
                 },
                 state
               )

      # Pi answers the refresh before it reads the later set_thinking_level,
      # so the refresh's get_state still reports "low".
      {state, pi, messages} = drive_fake_pi(refresh, state, pi)
      assert [mode_update, _config_update] = messages
      assert mode_update["params"]["update"]["currentModeId"] == "off"
      assert state.thinking_level == "off"
      assert state.available_thinking_levels == ["off", "minimal", "low"]

      # Pi then applies the level and reports the change it made.
      {state, _pi, []} = drive_fake_pi(set_level, state, pi)
      assert state.thinking_level == "off"
    end

    test "a rejected model switch restores the model Pi kept", %{state: state} do
      state = switch_ready_state(state)
      pi = %{fake_pi() | reject_set_model: "No API key for openai/gpt-5.1"}

      assert {:messages_and_write, [optimistic], data, state} =
               Pi.translate_outbound(set_model_request("openai/gpt-5.1"), state)

      assert Enum.find(optimistic["params"]["update"]["configOptions"], &(&1["id"] == "model"))[
               "currentValue"
             ] == "openai/gpt-5.1"

      {state, _pi, [_mode_update, config_update]} = drive_fake_pi(data, state, pi)

      assert state.current_model_id == "anthropic/claude-sonnet-4"
      assert state.available_thinking_levels == ["off", "medium", "high"]
      assert state.thinking_level == "high"

      assert Enum.find(config_update["params"]["update"]["configOptions"], &(&1["id"] == "model"))[
               "currentValue"
             ] == "anthropic/claude-sonnet-4"
    end

    test "a refresh on Pi 0.80.x falls back to the static levels", %{state: state} do
      state = switch_ready_state(state)
      pi = %{fake_pi() | thinking_levels_command?: false}

      assert {:messages_and_write, _, data, state} =
               Pi.translate_outbound(set_model_request("openai/gpt-5.1"), state)

      {state, _pi, [mode_update, _config_update]} = drive_fake_pi(data, state, pi)

      assert state.available_thinking_levels == ~w(off minimal low medium high xhigh)
      assert state.thinking_level == "low"
      assert mode_update["params"]["update"]["currentModeId"] == "low"
    end

    test "overlapping model switches converge on the model Pi applied", %{state: state} do
      # Pi finishes set_model requests in whatever order their auth checks
      # resolve. Try both orders.
      for order <- [:newest_first, :oldest_first] do
        state = switch_ready_state(state)
        pi = %{fake_pi() | hold_switches?: true}

        assert {:messages_and_write, _, first, state} =
                 Pi.translate_outbound(set_model_request("openai/gpt-5.1"), state)

        {state, pi, []} = drive_fake_pi(first, state, pi)

        assert {:messages_and_write, _, second, state} =
                 Pi.translate_outbound(set_model_request("anthropic/claude-opus-4"), state)

        {state, pi, _} = drive_fake_pi(second, state, pi)
        {state, pi, messages} = settle_fake_pi(state, pi, order)

        assert state.current_model_id == "#{pi.model["provider"]}/#{pi.model["id"]}",
               "#{order}: the adapter reports a model Pi did not end on"

        assert state.available_thinking_levels == pi.levels
        assert state.thinking_level == pi.level

        # The latest request is the one that sticks.
        assert pi.applied == ["openai/gpt-5.1", "anthropic/claude-opus-4"]
        assert state.current_model_id == "anthropic/claude-opus-4"
        assert state.pending_model_switch == nil
        assert state.pending_model_refresh == nil
        assert state.queued_model_switch == nil

        assert [mode_update, config_update] = messages
        assert mode_update["params"]["update"]["currentModeId"] == "xhigh"

        assert Enum.find(
                 config_update["params"]["update"]["configOptions"],
                 &(&1["id"] == "model")
               )[
                 "currentValue"
               ] == "anthropic/claude-opus-4"
      end
    end

    test "a switch requested during a refresh waits and the stale refresh is dropped", %{
      state: state
    } do
      state = switch_ready_state(state)
      pi = fake_pi()

      assert {:messages_and_write, _, first, state} =
               Pi.translate_outbound(set_model_request("openai/gpt-5.1"), state)

      {[level_event, switch_reply], pi} = fake_pi_answer(decode_many(first), pi)
      assert {:skip, state} = Pi.translate_inbound(Jason.encode!(level_event), state)

      assert {:skip_and_write, refresh, state} =
               Pi.translate_inbound(Jason.encode!(switch_reply), state)

      assert {:messages_and_write, [optimistic], "", state} =
               Pi.translate_outbound(set_model_request("anthropic/claude-opus-4"), state)

      assert Enum.find(optimistic["params"]["update"]["configOptions"], &(&1["id"] == "model"))[
               "currentValue"
             ] == "anthropic/claude-opus-4"

      # The refresh describes gpt-5.1; it is not published, and the waiting
      # switch goes out once it completes.
      {state, pi, messages} = drive_fake_pi(refresh, state, pi)

      assert pi.applied == ["openai/gpt-5.1", "anthropic/claude-opus-4"]
      assert [mode_update, _config_update] = messages
      assert mode_update["params"]["update"]["currentModeId"] == "xhigh"
      assert state.current_model_id == "anthropic/claude-opus-4"
      assert state.available_thinking_levels == ~w(off low medium high xhigh)
    end

    test "model switches stay bounded while Pi has not answered", %{state: state} do
      state = switch_ready_state(state)
      pi = %{fake_pi() | hold_switches?: true}

      assert {:messages_and_write, _, first, state} =
               Pi.translate_outbound(set_model_request("openai/gpt-5.1"), state)

      [%{"id" => first_id}] = decode_many(first)
      {state, pi, []} = drive_fake_pi(first, state, pi)

      request_switches = fn state, count ->
        Enum.map_reduce(1..count, state, fn n, state ->
          model = if rem(n, 2) == 0, do: "anthropic/claude-opus-4", else: "openai/gpt-5.1"

          assert {:messages_and_write, [_update], data, state} =
                   Pi.translate_outbound(set_model_request(model), state)

          {data, state}
        end)
      end

      {_writes, after_two} = request_switches.(state, 2)
      {writes, after_many} = request_switches.(state, 200)

      # The adapter state does not depend on how many switches were requested,
      # and nothing reaches Pi while the first switch is outstanding.
      assert after_many == after_two
      assert Enum.uniq(writes) == [""]
      assert after_many.pending_model_switch.rpc_id == first_id

      assert after_many.queued_model_switch.fields == %{
               "provider" => "anthropic",
               "modelId" => "claude-opus-4"
             }

      # Once Pi answers, only the latest waiting switch is sent.
      {state, pi, _messages} = settle_fake_pi(after_many, pi, :oldest_first)
      assert pi.applied == ["openai/gpt-5.1", "anthropic/claude-opus-4"]
      assert state.current_model_id == "anthropic/claude-opus-4"
      assert state.queued_model_switch == nil
    end

    test "a model switch waiting when the session changes never reaches the next session",
         ctx do
      for method <- ["session/load", "session/resume", "session/new"] do
        state = switch_ready_state(ctx.state)
        {refresh, state, pi} = refresh_with_waiting_switch(state)

        assert {:ok, setup, state} = Pi.translate_outbound(session_change(method, ctx), state)

        # Pi answers the refresh it read before the session change. While the
        # change is pending nothing is sent and nothing is published.
        state = feed_without_effect(refresh, state, pi, method)
        assert state.pending_model_refresh == nil

        # Pi confirms the change: s1's waiting switch is dropped, not sent.
        {state, messages} = finish_session_setup(setup, state, ctx)
        assert state.queued_model_switch == nil, "#{method} kept s1's waiting switch"
        assert state.pending_model_switch == nil
        assert state.session_id == "s2"
        assert state.current_model_id == "anthropic/claude-sonnet-4"
        assert state.available_thinking_levels == ["off", "high"]
        refute Enum.any?(messages, &(&1["params"]["sessionId"] == "s1"))
      end
    end

    # Pi rejects the change, or an extension cancels it (`cancelled: true`).
    for method <- ["session/load", "session/resume", "session/new"],
        outcome <- [:rejected, :cancelled] do
      @rejected_method method
      @change_outcome outcome
      test "a #{outcome} #{method} still sends s1's waiting switch", ctx do
        method = @rejected_method
        outcome = @change_outcome
        state = switch_ready_state(ctx.state)
        {refresh, state, pi} = refresh_with_waiting_switch(state)

        assert {:ok, setup, state} = Pi.translate_outbound(session_change(method, ctx), state)
        state = feed_without_effect(refresh, state, pi, method)

        assert {:messages_and_write, [error], next, state} =
                 reject_session_setup(setup, state, ctx, outcome)

        # The ACP request fails; it never reports s2 as the active session.
        assert error["id"] == 70
        refute Map.has_key?(error, "result")
        assert error["error"]["message"] == change_failure_message(outcome)

        assert [%{"type" => "set_model", "modelId" => "claude-opus-4"}] = decode_many(next),
               "#{method}: s1's waiting switch was not sent after the rejected change"

        {state, pi, messages} = drive_fake_pi(next, state, pi)
        assert pi.applied == ["openai/gpt-5.1", "anthropic/claude-opus-4"]
        assert state.session_id == "s1"
        assert state.current_model_id == "anthropic/claude-opus-4"
        assert state.available_thinking_levels == ~w(off low medium high xhigh)
        assert [mode_update, config_update] = messages
        assert mode_update["params"]["sessionId"] == "s1"
        assert config_update["params"]["sessionId"] == "s1"
      end
    end

    # Pi may answer the switch before or after it rejects the session change.
    for method <- ["session/load", "session/resume", "session/new"],
        order <- [:switch_reply_first, :rejection_first],
        outcome <- [:rejected, :cancelled] do
      @rejected_method method
      @switch_order order
      @change_outcome outcome
      test "a #{outcome} #{method} lets s1's outstanding switch refresh (#{order})", ctx do
        method = @rejected_method
        order = @switch_order
        outcome = @change_outcome
        state = switch_ready_state(ctx.state)
        pi = %{fake_pi() | hold_switches?: true}

        assert {:messages_and_write, _, first, state} =
                 Pi.translate_outbound(set_model_request("openai/gpt-5.1"), state)

        {state, pi, []} = drive_fake_pi(first, state, pi)
        assert {:ok, setup, state} = Pi.translate_outbound(session_change(method, ctx), state)

        {state, pi, messages} =
          reject_with_switch_outstanding(order, setup, state, pi, ctx, outcome)

        assert state.session_id == "s1"
        assert state.current_model_id == "openai/gpt-5.1"
        assert state.available_thinking_levels == ["off", "minimal", "low"]

        assert [mode_update, config_update] = messages,
               "#{method}/#{order}: s1's switch was not refreshed"

        assert mode_update["params"]["sessionId"] == "s1"
        assert config_update["params"]["sessionId"] == "s1"
        assert pi.applied == ["openai/gpt-5.1"]
      end
    end

    # The ACP client sends $/cancel_request when the request times out, when
    # its caller cancels it, and when the caller goes away. The request fails
    # at once, but Pi's answer to the change, whenever it comes, decides what
    # happens to the held model work. A session_before_switch extension that
    # never resolves means that answer never comes.
    for method <- ["session/load", "session/resume", "session/new"],
        late <- [:rejected, :cancelled, :succeeded] do
      @cancelled_method method
      @late_outcome late
      test "a #{method} cancelled before Pi answers waits for Pi (late #{late})", ctx do
        method = @cancelled_method
        late = @late_outcome
        state = with_session_file(switch_ready_state(ctx.state), ctx)
        {refresh, state, pi} = refresh_with_waiting_switch(state)

        assert {:ok, setup, state} = Pi.translate_outbound(session_change(method, ctx), state)
        state = feed_without_effect(refresh, state, pi, method)
        [change] = decode_many(setup)

        assert {:messages, [error], state} = Pi.translate_outbound(cancel_request(70), state),
               "#{method}: the cancel released or sent something before Pi answered"

        assert error["id"] == 70
        assert error["error"]["code"] == -32_800
        assert MapSet.member?(state.pending_session_changes, change["id"])
        assert state.control_groups == %{}

        next = answer_cancelled_change(late, change, state)
        assert [%{"type" => "set_model", "modelId" => "claude-opus-4"}] = decode_many(next)
      end
    end

    # The change succeeded, so the setup's queries were already sent when the
    # client cancelled it. Pi is returned to s1; the queries may be answered
    # before or after Pi answers that switch.
    for order <- [:queries_first, :restore_first] do
      @reply_order order
      test "a setup cancelled after its change succeeded returns Pi to s1 (#{order})", ctx do
        state = with_session_file(switch_ready_state(ctx.state), ctx)
        before = Map.take(state, [:session_id, :session_file, :cwd, :workspace_root])

        assert {:ok, setup, state} =
                 Pi.translate_outbound(session_change("session/load", ctx), state)

        {[_change | queries], state} = confirm_session_change(setup, state)

        assert {:messages_and_write, [error], back, state} =
                 Pi.translate_outbound(cancel_request(70), state)

        assert error["error"]["code"] == -32_800
        assert [%{"type" => "switch_session"} = restore] = decode_many(back)
        assert restore["sessionPath"] == before.session_file

        answer_queries = fn state ->
          {state, []} =
            Enum.reduce(queries, {state, []}, fn query, {state, []} ->
              data = %{
                "sessionId" => "s2",
                "thinkingLevel" => "low",
                "models" => [],
                "levels" => []
              }

              assert {:skip, state} =
                       Pi.translate_inbound(
                         response_line(query["id"], query["type"], data),
                         state
                       )

              {state, []}
            end)

          state
        end

        answer_restore = fn state ->
          assert {:skip, state} =
                   Pi.translate_inbound(
                     response_line(restore["id"], "switch_session", %{}),
                     state
                   )

          state
        end

        steps = %{queries: answer_queries, restore: answer_restore}
        state = Enum.reduce(reply_steps(@reply_order), state, &Map.fetch!(steps, &1).(&2))

        assert Map.take(state, [:session_id, :session_file, :cwd, :workspace_root]) == before
        assert state.pending_session_changes == MapSet.new()
        assert state.retired_rpc_ids == MapSet.new()
      end
    end

    test "a cancelled setup's outstanding switch refreshes once Pi answers the change", ctx do
      state = switch_ready_state(ctx.state)
      pi = %{fake_pi() | hold_switches?: true}

      assert {:messages_and_write, _, first, state} =
               Pi.translate_outbound(set_model_request("openai/gpt-5.1"), state)

      {state, pi, []} = drive_fake_pi(first, state, pi)

      assert {:ok, setup, state} =
               Pi.translate_outbound(session_change("session/load", ctx), state)

      [change] = decode_many(setup)

      assert {:messages, [%{"id" => 70, "error" => %{"code" => -32_800}}], state} =
               Pi.translate_outbound(cancel_request(70), state)

      # The switch's answer comes while the change is still unanswered: held.
      {[_level_event, switch_reply], pi} = fake_pi_reply(hd(pi.held), %{pi | held: []})
      assert {:skip, state} = Pi.translate_inbound(Jason.encode!(switch_reply), state)

      assert {:skip_and_write, refresh, state} =
               Pi.translate_inbound(Jason.encode!(change_failure(change, :rejected)), state)

      {state, _pi, messages} = drive_fake_pi(refresh, state, %{pi | hold_switches?: false})
      assert state.current_model_id == "openai/gpt-5.1"
      assert [mode_update, config_update] = messages
      assert mode_update["params"]["sessionId"] == "s1"
      assert config_update["params"]["sessionId"] == "s1"
    end

    test "a setup arriving while a cancelled change is unanswered waits for Pi", ctx do
      state = switch_ready_state(ctx.state)

      assert {:ok, setup, state} =
               Pi.translate_outbound(session_change("session/load", ctx), state)

      [change] = decode_many(setup)
      assert {:messages, [_error], state} = Pi.translate_outbound(cancel_request(70), state)

      assert {:ok, :skip, state} = Pi.translate_outbound(session_change_new(71, ctx), state)

      assert {:skip_and_write, next, _state} =
               Pi.translate_inbound(Jason.encode!(change_failure(change, :rejected)), state)

      assert [%{"type" => "new_session"}] = decode_many(next)
    end

    test "cancelling another request leaves a pending setup alone", ctx do
      state = switch_ready_state(ctx.state)

      assert {:ok, _setup, state} =
               Pi.translate_outbound(session_change("session/load", ctx), state)

      assert {:ok, :skip, ^state} = Pi.translate_outbound(cancel_request(71), state)
      assert MapSet.size(state.pending_session_changes) == 1
    end

    test "Pi exiting during a session change releases nothing and holds nothing", ctx do
      state = switch_ready_state(ctx.state)
      {_refresh, state, _pi} = refresh_with_waiting_switch(state)

      assert {:ok, _setup, state} =
               Pi.translate_outbound(session_change("session/load", ctx), state)

      assert {:messages, [%{"id" => 70, "error" => _}], state} =
               Pi.handle_adapter_message({nil, {:exit_status, 1}}, state)

      assert state.pending_session_changes == MapSet.new()
      assert state.queued_model_switch == nil
      assert state.pending_model_refresh == nil

      assert {:messages_and_write, _, data, _state} =
               Pi.translate_outbound(set_model_request("openai/gpt-5.1"), state)

      assert [%{"type" => "set_model"}] = decode_many(data)
    end

    test "a model switch outstanding when the session changes is consumed without effect", ctx do
      for method <- ["session/load", "session/new", "session/close"] do
        state = switch_ready_state(ctx.state)
        pi = %{fake_pi() | hold_switches?: true}

        assert {:messages_and_write, _, first, state} =
                 Pi.translate_outbound(set_model_request("openai/gpt-5.1"), state)

        {state, pi, []} = drive_fake_pi(first, state, pi)

        state =
          case Pi.translate_outbound(session_change(method, ctx), state) do
            {:ok, setup, state} -> setup |> finish_session_setup(state, ctx) |> elem(0)
            {:reply, %{}, state} -> state
          end

        # Pi's reply to the old switch arrives after the session changed. Pi
        # rebinds its event stream on a switch, so only the response arrives.
        {[_level_event, switch_reply], _pi} = fake_pi_reply(hd(pi.held), pi)

        assert {:skip, state} = Pi.translate_inbound(Jason.encode!(switch_reply), state),
               "#{method}: the old switch's reply started a refresh"

        assert state.pending_model_switch == nil
        assert state.pending_model_refresh == nil

        if method != "session/close" do
          assert state.current_model_id == "anthropic/claude-sonnet-4"
        end
      end
    end

    test "a switch for the next session waits for the old outstanding switch", ctx do
      state = switch_ready_state(ctx.state)
      pi = %{fake_pi() | hold_switches?: true}

      assert {:messages_and_write, _, first, state} =
               Pi.translate_outbound(set_model_request("openai/gpt-5.1"), state)

      {state, pi, []} = drive_fake_pi(first, state, pi)

      assert {:ok, setup, state} =
               Pi.translate_outbound(session_change("session/load", ctx), state)

      {state, _messages} = finish_session_setup(setup, state, ctx)

      # Model switches stay serialized across the session change.
      assert {:messages_and_write, _, "", state} =
               Pi.translate_outbound(
                 %{
                   "method" => "session/set_model",
                   "params" => %{"sessionId" => "s2", "modelId" => "anthropic/claude-opus-4"}
                 },
                 state
               )

      {[_level_event, old_reply], pi} = fake_pi_reply(hd(pi.held), %{pi | held: []})

      assert {:skip_and_write, next, state} =
               Pi.translate_inbound(Jason.encode!(old_reply), state)

      assert [%{"type" => "set_model", "modelId" => "claude-opus-4"}] = decode_many(next)

      {state, _pi, messages} = drive_fake_pi(next, state, %{pi | hold_switches?: false})
      assert state.current_model_id == "anthropic/claude-opus-4"
      assert [mode_update, config_update] = messages
      assert mode_update["params"]["sessionId"] == "s2"
      assert config_update["params"]["sessionId"] == "s2"
    end

    test "a usage request is published unless the session change took effect", ctx do
      stats = fn state ->
        Pi.translate_inbound(
          response_line("pi-90", "get_session_stats", %{
            "contextUsage" => %{"tokens" => 120, "contextWindow" => 200_000}
          }),
          state
        )
      end

      state = %{switch_ready_state(ctx.state) | pending_usage_request: {"pi-90", "s1"}}

      assert {:ok, setup, state} =
               Pi.translate_outbound(session_change("session/load", ctx), state)

      {confirmed, _messages} = finish_session_setup(setup, state, ctx)
      assert {:skip, confirmed} = stats.(confirmed)
      assert confirmed.pending_usage_request == nil

      assert {:messages, [_error], rejected} = reject_session_setup(setup, state, ctx)
      assert {:messages, [usage], _rejected} = stats.(rejected)
      assert usage["params"]["sessionId"] == "s1"
      assert usage["params"]["update"]["sessionUpdate"] == "usage_update"
    end

    for method <- ["session/load", "session/resume", "session/new"] do
      @setup_method method
      test "#{method} setup replies describe the session Pi switched to", ctx do
        method = @setup_method
        state = switch_ready_state(ctx.state)
        pi = session_pi(ctx)

        assert {:ok, data, state} = Pi.translate_outbound(session_change(method, ctx), state)

        # Pi replaces its session asynchronously. Whatever it reads before the
        # change completes is answered from the session it is leaving.
        {replies, pi} = session_pi_answer(decode_many(data), pi)
        {state, pi, early} = drive_session_pi(replies, state, pi)
        {change_reply, pi} = finish_session_pi_change(pi)
        {state, _pi, late} = drive_session_pi([change_reply], state, pi)

        assert %{"result" => result} = Enum.find(early ++ late, &(&1["id"] == 70))
        expected = if method == "session/new", do: "fresh", else: "s2"
        %{level: level, levels: levels, model: model} = pi.sessions[expected]

        assert result["sessionId"] == expected
        assert result["models"]["currentModelId"] == "#{model["provider"]}/#{model["id"]}"

        assert result["modes"]["currentModeId"] == level,
               "#{method} reported the previous session's thinking level"

        assert Enum.map(result["modes"]["availableModes"], & &1["id"]) == levels
        assert state.session_id == expected
        assert state.session_file == pi.sessions[expected].file

        replayed =
          for %{"params" => %{"update" => %{"content" => %{"text" => text}}}} <- early ++ late,
              do: text

        assert replayed == if(method == "session/load", do: ["from s2"], else: [])
      end
    end

    # Pi finishes overlapping session changes in either order, and answers a
    # setup's queries from whichever session is active when it reads them.
    for order <- [:newest_first, :oldest_first] do
      @overlap_order order
      test "overlapping setups each describe their own session (#{order})", ctx do
        order = @overlap_order
        state = switch_ready_state(ctx.state)
        pi = %{session_pi(ctx) | pending_change: []} |> Map.put(:held_queries, [])

        {state, pi, messages} =
          Enum.reduce(
            [session_change("session/load", ctx), session_change_new(71, ctx)],
            {state, pi, []},
            fn request, {state, pi, messages} ->
              {state, writes, new} = outbound_writes(Pi.translate_outbound(request, state))
              {state, overlap_pi_receive(writes, pi), messages ++ new}
            end
          )

        {state, pi, messages} = settle_overlap_pi(state, pi, order, messages)

        load = Enum.find(messages, &(&1["id"] == 70))
        new = Enum.find(messages, &(&1["id"] == 71))

        for {response, id} <- [{load, "s2"}, {new, "fresh"}] do
          %{level: level, model: model} = pi.sessions[id]
          assert response["result"]["sessionId"] == id

          assert response["result"]["models"]["currentModelId"] ==
                   "#{model["provider"]}/#{model["id"]}",
                 "#{order}: the #{id} setup reported another session's model"

          assert response["result"]["modes"]["currentModeId"] == level
        end

        # The adapter ends on the session Pi ends on.
        assert state.session_id == pi.active
      end
    end

    test "a waiting setup the client cancels never starts", ctx do
      state = switch_ready_state(ctx.state)

      assert {:ok, setup, state} =
               Pi.translate_outbound(session_change("session/load", ctx), state)

      assert {:ok, :skip, state} = Pi.translate_outbound(session_change_new(71, ctx), state)

      assert {:messages, [%{"id" => 71, "error" => %{"code" => -32_800}}], state} =
               Pi.translate_outbound(cancel_request(71), state)

      assert state.queued_session_setups == []

      # The first setup completes and nothing else is written.
      {state, messages} = finish_session_setup(setup, state, ctx)
      assert Enum.any?(messages, &(&1["id"] == 70))
      assert state.session_id == "s2"
    end

    test "a failed session change keeps the previous session's workspace", ctx do
      other = Path.join(ctx.tmp_dir, "other")
      File.mkdir_p!(other)

      for method <- ["session/load", "session/new"], outcome <- [:rejected, :cancelled] do
        state = %{switch_ready_state(ctx.state) | startup_sent?: true}
        before = Map.take(state, [:cwd, :workspace_root, :settings, :last_session_cwd])
        request = put_in(session_change(method, ctx), ["params", "cwd"], other)

        assert {:ok, setup, state} = Pi.translate_outbound(request, state)
        assert state.workspace_root == other

        assert {:messages, [_error], state} = reject_session_setup(setup, state, ctx, outcome)

        assert Map.take(state, [:cwd, :workspace_root, :settings, :last_session_cwd]) == before,
               "#{method}/#{outcome} left the adapter on the requested workspace"

        assert state.startup_sent?
        assert state.session_id == "s1"
      end
    end

    for closer <- ["session/close", "session/delete"],
        {running, queued} <- [{"session/load", "session/new"}, {"session/new", "session/load"}] do
      @closer closer
      @running_setup running
      @queued_setup queued
      test "a #{queued} waiting behind a #{running} that #{closer} drops starts at once", ctx do
        state = switch_ready_state(ctx.state)
        running = session_setup_request(@running_setup, 70, ctx)
        queued = session_setup_request(@queued_setup, 71, ctx)

        assert {:ok, _running_setup, state} = Pi.translate_outbound(running, state)
        assert {:ok, :skip, state} = Pi.translate_outbound(queued, state)

        close = %{"method" => @closer, "id" => 72, "params" => %{"sessionId" => "s1"}}

        assert {:reply_and_write, %{}, setup, state} = Pi.translate_outbound(close, state),
               "#{@closer} left the #{@queued_setup} waiting"

        assert [%{"type" => change}] = decode_many(setup)
        assert change in ["new_session", "switch_session"]
        assert state.queued_session_setups == []

        {state, messages} = finish_session_setup(setup, state, ctx)
        assert %{"result" => %{"sessionId" => "s2"}} = Enum.find(messages, &(&1["id"] == 71))
        assert state.session_id == "s2"
      end
    end

    # A setup query can still be answered after its setup ended: here the
    # catalog query fails first and get_state is answered later.
    for order <- [:late_reply_first, :next_session_first] do
      @late_order order
      test "a late setup query reply after the setup failed changes nothing (#{order})", ctx do
        state = switch_ready_state(ctx.state)

        assert {:ok, setup, state} =
                 Pi.translate_outbound(session_change("session/load", ctx), state)

        {[_change | followups], state} = confirm_session_change(setup, state)
        by_type = Map.new(followups, &{&1["type"], &1["id"]})

        failure =
          Jason.encode!(%{
            "type" => "response",
            "id" => by_type["get_available_models"],
            "command" => "get_available_models",
            "success" => false,
            "error" => "catalog unavailable"
          })

        {state, [error]} = result_state_and_messages(Pi.translate_inbound(failure, state))
        assert error["id"] == 70

        state =
          if @late_order == :next_session_first do
            state = settle_session_change_restore(state)
            assert {:ok, next, state} = Pi.translate_outbound(session_change_new(71, ctx), state)
            {state, _messages} = finish_session_setup(next, state, ctx)
            state
          else
            state
          end

        before = Map.take(state, [:session_id, :session_file, :thinking_level])

        late =
          response_line(by_type["get_state"], "get_state", %{
            "sessionId" => "stale",
            "sessionFile" => Path.join(ctx.session_dir, "stale.jsonl"),
            "thinkingLevel" => "xhigh"
          })

        assert {:skip, state} = Pi.translate_inbound(late, state)

        assert Map.take(state, [:session_id, :session_file, :thinking_level]) == before,
               "#{@late_order}: a late get_state reply repointed the session"
      end
    end

    test "thinking_level_changed events publish the level Pi applied", %{state: state} do
      state = switch_ready_state(state)

      assert {:messages, [mode_update, config_update], state} =
               Pi.translate_inbound(
                 Jason.encode!(%{"type" => "thinking_level_changed", "level" => "medium"}),
                 state
               )

      assert mode_update["params"]["sessionId"] == "s1"
      assert mode_update["params"]["update"]["currentModeId"] == "medium"

      thought =
        Enum.find(
          config_update["params"]["update"]["configOptions"],
          &(&1["id"] == "thought_level")
        )

      assert thought["currentValue"] == "medium"
      assert state.thinking_level == "medium"

      assert {:skip, ^state} =
               Pi.translate_inbound(
                 Jason.encode!(%{"type" => "thinking_level_changed", "level" => "medium"}),
                 state
               )
    end

    test "session/set_model routes full ACP model IDs to Pi set_model", %{state: state} do
      msg = %{
        "method" => "session/set_model",
        "params" => %{"modelId" => "anthropic/claude-sonnet-4"}
      }

      assert {:messages_and_write, [update], data, new_state} = Pi.translate_outbound(msg, state)
      decoded = decode_one(data)
      assert decoded["type"] == "set_model"
      assert decoded["provider"] == "anthropic"
      assert decoded["modelId"] == "claude-sonnet-4"
      assert new_state.current_model_id == "anthropic/claude-sonnet-4"
      assert update["params"]["update"]["sessionUpdate"] == "config_option_update"
    end

    test "session/set_model resolves bare model IDs from available models", %{state: state} do
      state = %{state | available_models: [%{"modelId" => "openai/gpt-5.1"}]}
      msg = %{"method" => "session/set_model", "params" => %{"modelId" => "gpt-5.1"}}

      assert {:messages_and_write, [_update], data, new_state} = Pi.translate_outbound(msg, state)
      decoded = decode_one(data)
      assert decoded["provider"] == "openai"
      assert decoded["modelId"] == "gpt-5.1"
      assert new_state.current_model_id == "openai/gpt-5.1"
    end

    test "session/set_model rejects unknown bare IDs", %{state: state} do
      msg = %{"method" => "session/set_model", "params" => %{"modelId" => "missing-model"}}

      assert {:error, "Unknown modelId: missing-model", ^state} =
               Pi.translate_outbound(msg, state)
    end

    test "session/set_mode routes thinking level and emits current_mode_update", %{state: state} do
      msg = %{
        "method" => "session/set_mode",
        "params" => %{"sessionId" => "s1", "modeId" => "high"}
      }

      assert {:messages_and_write, [mode_update, config_update], data, new_state} =
               Pi.translate_outbound(msg, state)

      assert mode_update["params"]["update"]["currentModeId"] == "high"
      assert config_update["params"]["update"]["sessionUpdate"] == "config_option_update"
      assert decode_one(data)["type"] == "set_thinking_level"
      assert new_state.thinking_level == "high"
    end

    test "session/set_mode rejects invalid thinking levels", %{state: state} do
      msg = %{"method" => "session/set_mode", "params" => %{"modeId" => "invalid"}}
      assert {:error, "Unknown modeId: \"invalid\"", ^state} = Pi.translate_outbound(msg, state)
    end

    test "auto_compaction routes to set_auto_compaction", %{state: state} do
      msg = %{
        "method" => "session/set_config_option",
        "params" => %{"configId" => "auto_compaction", "value" => false}
      }

      assert {:ok, data, _state} = Pi.translate_outbound(msg, state)
      assert decode_one(data) == %{"type" => "set_auto_compaction", "enabled" => false}
    end

    test "model config option routes to set_model and emits config option update", %{
      state: state
    } do
      state = %{
        state
        | session_id: "s1",
          available_models: [
            %{"modelId" => "test/alpha", "name" => "test/Alpha", "description" => nil},
            %{"modelId" => "test/beta", "name" => "test/Beta", "description" => nil}
          ],
          current_model_id: "test/alpha"
      }

      msg = %{
        "method" => "session/set_config_option",
        "params" => %{"configId" => "model", "value" => "test/beta"}
      }

      assert {:messages_and_write, [update], data, new_state} =
               Pi.translate_outbound(msg, state)

      assert {"pi-" <> _, set_model} = Map.pop(decode_one(data), "id")
      assert set_model == %{"type" => "set_model", "provider" => "test", "modelId" => "beta"}

      assert new_state.current_model_id == "test/beta"

      option =
        update["params"]["update"]["configOptions"]
        |> Enum.find(&(&1["id"] == "model"))

      assert option["currentValue"] == "test/beta"
    end

    test "managed model confirmation does not repeat the full model catalog", %{state: state} do
      # Keep both stdio pipes attached: redirecting stdout to /dev/null lets
      # the port observe EOF before the managed write on Linux. Read the echo
      # before closing so the fixture also verifies the native RPC command.
      {:ok, port} = PortRunner.open("cat", [], [], Pi)

      on_exit(fn -> PortRunner.close(port) end)

      available_models =
        Enum.map(1..300, fn index ->
          %{
            "modelId" => "test/model-#{index}",
            "name" => "test/Model #{index}",
            "description" => String.duplicate("catalog entry ", 20)
          }
        end)

      state = %{
        state
        | managed?: true,
          port: port,
          session_id: "s1",
          available_models: available_models,
          current_model_id: "test/model-1"
      }

      msg = %{
        "method" => "session/set_config_option",
        "params" => %{"configId" => "model", "value" => "test/model-300"}
      }

      assert {:messages_and_reply, [update], %{"configOptions" => confirmation}, new_state} =
               Pi.translate_outbound(msg, state)

      generation = PortRunner.identity(port)
      assert_receive {:arbor_rpc, ^generation, {:frame, token, rpc_line}}, 1_000
      assert :ok = PortRunner.ack(port, token)

      assert {"pi-" <> _, set_model} = Map.pop(Jason.decode!(rpc_line), "id")

      assert set_model == %{
               "type" => "set_model",
               "provider" => "test",
               "modelId" => "model-300"
             }

      confirmed_model = Enum.find(confirmation, &(&1["id"] == "model"))
      assert confirmed_model["currentValue"] == "test/model-300"
      refute Map.has_key?(confirmed_model, "options")

      advertised_model =
        update["params"]["update"]["configOptions"]
        |> Enum.find(&(&1["id"] == "model"))

      assert length(advertised_model["options"]) == 300
      assert new_state.current_model_id == "test/model-300"
    end

    test "managed model confirmation reports missing and closed ports", %{state: state} do
      {:ok, port} = PortRunner.open("cat", [], [], Pi)
      PortRunner.close(port)

      msg = %{
        "method" => "session/set_config_option",
        "params" => %{"configId" => "model", "value" => "test/model"}
      }

      for {port, reason} <- [{nil, ":no_active_pi_session"}, {port, ":badarg"}] do
        state = %{state | managed?: true, port: port, session_id: "s1"}
        assert {:error, ^reason, _next_state} = Pi.translate_outbound(msg, state)
      end
    end

    test "thought_level config option routes to set_thinking_level and emits sync updates", %{
      state: state
    } do
      state = %{state | session_id: "s1", thinking_level: "medium"}

      msg = %{
        "method" => "session/set_config_option",
        "params" => %{"configId" => "thought_level", "value" => "xhigh"}
      }

      assert {:messages_and_write, [mode_update, config_update], data, new_state} =
               Pi.translate_outbound(msg, state)

      assert decode_one(data) == %{"type" => "set_thinking_level", "level" => "xhigh"}
      assert new_state.thinking_level == "xhigh"
      assert mode_update["params"]["update"]["currentModeId"] == "xhigh"

      option =
        config_update["params"]["update"]["configOptions"]
        |> Enum.find(&(&1["id"] == "thought_level"))

      assert option["currentValue"] == "xhigh"
    end

    test "unknown config option returns an error", %{state: state} do
      msg = %{
        "method" => "session/set_config_option",
        "params" => %{"configId" => "nonexistent", "value" => "x"}
      }

      assert {:error, "Unknown Pi config option: nonexistent", ^state} =
               Pi.translate_outbound(msg, state)
    end
  end

  describe "translate_outbound/2 — prompting and slash commands" do
    test "session/prompt produces Pi RPC prompt with content block normalization", %{state: state} do
      msg = %{
        "method" => "session/prompt",
        "id" => 21,
        "params" => %{
          "sessionId" => "s1",
          "prompt" => [
            %{"type" => "text", "text" => "Hello"},
            %{"type" => "resource_link", "uri" => "file:///tmp/example.ex"},
            %{"type" => "audio", "mimeType" => "audio/wav", "data" => "abc"}
          ]
        }
      }

      assert {:ok, data, new_state} = Pi.translate_outbound(msg, state)
      decoded = decode_one(data)
      assert decoded["type"] == "prompt"
      assert decoded["message"] =~ "Hello"
      assert decoded["message"] =~ "[Context] file:///tmp/example.ex"
      assert decoded["message"] =~ "[Audio]"
      assert new_state.pending_prompt.acp_id == 21
    end

    test "image prompts pass normalized images to Pi", %{state: state} do
      msg = %{
        "method" => "session/prompt",
        "id" => 22,
        "params" => %{
          "prompt" => [
            %{"type" => "text", "text" => "What is this?"},
            %{
              "type" => "image",
              "mimeType" => "image/png",
              "data" => "data:image/png;base64,abc123"
            }
          ]
        }
      }

      assert {:ok, data, _state} = Pi.translate_outbound(msg, state)
      decoded = decode_one(data)

      assert decoded["images"] == [
               %{"type" => "image", "mimeType" => "image/png", "data" => "abc123"}
             ]
    end

    test "queued prompts stay pending and run after the active turn ends", %{state: state} do
      state = %{
        state
        | pending_prompt: %{acp_id: 1, msg_id: "msg-1", cancel_requested: false},
          session_id: "s1"
      }

      msg = %{
        "method" => "session/prompt",
        "id" => 23,
        "params" => %{"sessionId" => "s1", "prompt" => "second"}
      }

      assert {:messages, [_notice, _info], queued_state} = Pi.translate_outbound(msg, state)
      assert PromptQueue.len(queued_state.prompt_queue) == 1

      assert {:skip_and_write, usage_request, queued_state} =
               Pi.translate_inbound(
                 Jason.encode!(%{"type" => "agent_end", "messages" => []}),
                 queued_state
               )

      assert decode_one(usage_request)["type"] == "get_session_stats"

      assert {:messages_and_write, [first_response, _start_notice, _queue_info], data, next_state} =
               Pi.translate_inbound(Jason.encode!(%{"type" => "agent_settled"}), queued_state)

      assert first_response["id"] == 1
      assert decode_one(data)["message"] == "second"
      assert next_state.pending_prompt.acp_id == 23
    end

    test "session/cancel cancels queued prompts and marks active prompt", %{state: state} do
      queue =
        PromptQueue.new()
        |> PromptQueue.enqueue(%{acp_id: 31, message: "queued", images: [], params: %{}})

      state = %{
        state
        | session_id: "s1",
          pending_prompt: %{acp_id: 30, msg_id: "msg-1", cancel_requested: false},
          prompt_queue: queue
      }

      assert {:messages_and_write, messages, data, new_state} =
               Pi.translate_outbound(%{"method" => "session/cancel"}, state)

      assert Enum.any?(messages, &(&1["id"] == 31))

      assert Enum.any?(
               messages,
               &(get_in(&1, ["params", "update", "content", "text"]) == "Cleared queued prompts.")
             )

      assert decode_one(data)["type"] == "abort"
      assert new_state.pending_prompt.cancel_requested == true
      assert PromptQueue.empty?(new_state.prompt_queue)
    end

    test "slash compact maps to Pi compact and replies after control response", %{state: state} do
      msg = %{
        "method" => "session/prompt",
        "id" => 24,
        "params" => %{"sessionId" => "s1", "prompt" => "/compact keep tests"}
      }

      assert {:ok, data, state} = Pi.translate_outbound(msg, %{state | session_id: "s1"})
      request = decode_one(data)
      assert request["type"] == "compact"
      assert request["customInstructions"] == "keep tests"

      assert {:messages, [message, response], _state} =
               Pi.translate_inbound(
                 response_line(request["id"], "compact", %{
                   "summary" => "done",
                   "tokensBefore" => 12
                 }),
                 state
               )

      assert get_in(message, ["params", "update", "content", "text"]) =~ "Compaction completed."
      assert response["id"] == 24
      assert response["result"]["stopReason"] == "end_turn"
    end

    test "file slash commands expand to prompts", %{state: state, tmp_dir: tmp_dir} do
      prompts_dir = Path.join([tmp_dir, ".pi", "prompts"])
      File.mkdir_p!(prompts_dir)
      File.write!(Path.join(prompts_dir, "review.md"), "Review $1 and $@")

      msg = %{"method" => "session/new", "id" => 25, "params" => %{"cwd" => tmp_dir}}
      assert {:ok, _data, state} = Pi.translate_outbound(msg, state)

      state = %{
        state
        | file_commands:
            state.control_groups |> Map.values() |> hd() |> Map.fetch!(:file_commands)
      }

      prompt_msg = %{
        "method" => "session/prompt",
        "id" => 26,
        "params" => %{"prompt" => "/review src all files"}
      }

      assert {:ok, data, _state} = Pi.translate_outbound(prompt_msg, state)
      assert decode_one(data)["message"] == "Review src and src all files"
    end

    test "removed extension methods return explicit errors", %{state: state} do
      msg = %{"method" => "_ex_mcp.pi/steer", "params" => %{"message" => "look at diff"}}

      assert {:error,
              "Pi extension methods were removed; use ACP session methods or slash commands",
              ^state} = Pi.translate_outbound(msg, state)
    end
  end

  describe "translate_inbound/2 — text streaming" do
    test "text_delta produces agent_message_chunk", %{state: state} do
      line =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "Hello"}
        })

      assert {:messages, [notification], new_state} = Pi.translate_inbound(line, state)
      assert notification["method"] == "session/update"
      update = notification["params"]["update"]
      assert update["sessionUpdate"] == "agent_message_chunk"
      assert update["content"]["text"] == "Hello"
      assert new_state.text_acc == ["Hello"]
    end

    test "thinking_delta produces thinking update", %{state: state} do
      line =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "thinking_delta", "delta" => "Let me think..."}
        })

      assert {:messages, [notification], _state} = Pi.translate_inbound(line, state)
      update = notification["params"]["update"]
      assert update["sessionUpdate"] == "agent_thought_chunk"
      assert update["content"] == %{"type" => "text", "text" => "Let me think..."}
    end
  end

  describe "handle_adapter_message/2 — batched events" do
    test "preserves every message when Pi emits multiple events in one port chunk", %{
      state: state
    } do
      events = [
        %{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "thinking_start", "contentIndex" => 0}
        },
        %{
          "type" => "message_update",
          "assistantMessageEvent" => %{
            "type" => "thinking_delta",
            "contentIndex" => 0,
            "delta" => "Let"
          }
        },
        %{
          "type" => "message_update",
          "assistantMessageEvent" => %{
            "type" => "thinking_delta",
            "contentIndex" => 0,
            "delta" => " me"
          }
        }
      ]

      data = Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n"
      state = %{state | port: :pi_port}

      assert {:messages, [first, second], new_state} =
               Pi.handle_adapter_message({:pi_port, {:data, data}}, state)

      assert first["params"]["update"]["sessionUpdate"] == "agent_thought_chunk"
      assert first["params"]["update"]["content"]["text"] == "Let"
      assert second["params"]["update"]["sessionUpdate"] == "agent_thought_chunk"
      assert second["params"]["update"]["content"]["text"] == " me"
      assert new_state.buffer == ""
    end
  end

  describe "translate_inbound/2 — agent settlement" do
    test "unreliable context counts do not become ACP usage updates", %{state: state} do
      state = %{state | session_id: "s1", pending_usage_request: {"pi-1", "s1"}}

      assert {:skip, state} =
               Pi.translate_inbound(
                 response_line("pi-1", "get_session_stats", %{
                   "contextUsage" => %{"tokens" => nil, "contextWindow" => 200_000}
                 }),
                 state
               )

      assert state.pending_usage_request == nil
    end

    test "agent_end records usage and agent_settled produces the prompt response", %{state: state} do
      state = %{
        state
        | session_id: "s1",
          pending_prompt: %{acp_id: 5, msg_id: "msg-1", cancel_requested: false},
          text_acc: ["world", "Hello "]
      }

      line =
        Jason.encode!(%{
          "type" => "agent_end",
          "messages" => [%{"role" => "assistant", "usage" => %{"input" => 10, "output" => 2}}]
        })

      assert {:skip_and_write, usage_request, state} = Pi.translate_inbound(line, state)
      assert %{"type" => "get_session_stats", "id" => usage_id} = decode_one(usage_request)
      assert state.pending_prompt.acp_id == 5

      assert {:messages, [usage_update], state} =
               Pi.translate_inbound(
                 response_line(usage_id, "get_session_stats", %{
                   "contextUsage" => %{"tokens" => 120, "contextWindow" => 200_000}
                 }),
                 state
               )

      assert usage_update["params"]["update"] == %{
               "sessionUpdate" => "usage_update",
               "used" => 120,
               "size" => 200_000
             }

      assert {:messages, [response], new_state} =
               Pi.translate_inbound(Jason.encode!(%{"type" => "agent_settled"}), state)

      assert response["id"] == 5
      assert response["result"]["_meta"]["ex_mcp"]["text"] == "Hello world"
      assert response["result"]["usage"]["inputTokens"] == 10
      assert response["result"]["stopReason"] == "end_turn"
      assert new_state.pending_prompt == nil
      assert new_state.text_acc == []
    end
  end

  describe "translate_inbound/2 — tool execution" do
    test "tool_execution_start emits a new tool call with locations", %{
      state: state,
      tmp_dir: tmp_dir
    } do
      line =
        Jason.encode!(%{
          "type" => "tool_execution_start",
          "toolCallId" => "tc-1",
          "toolName" => "read",
          "args" => %{"path" => "lib/example.ex"}
        })

      assert {:messages, [notification], _state} =
               Pi.translate_inbound(line, %{state | cwd: tmp_dir})

      update = notification["params"]["update"]
      assert update["sessionUpdate"] == "tool_call"
      assert update["status"] == "in_progress"
      assert update["title"] == "read"
      assert hd(update["locations"])["path"] == Path.join(tmp_dir, "lib/example.ex")
    end

    test "toolcall_start and toolcall_delta emit call then update", %{state: state} do
      start =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{
            "type" => "toolcall_start",
            "toolCall" => %{
              "id" => "tc-stream",
              "name" => "bash",
              "arguments" => %{"command" => "ls"}
            }
          }
        })

      assert {:messages, [call], state} = Pi.translate_inbound(start, state)
      assert call["params"]["update"]["sessionUpdate"] == "tool_call"

      delta =
        Jason.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{
            "type" => "toolcall_delta",
            "toolCall" => %{
              "id" => "tc-stream",
              "name" => "bash",
              "arguments" => %{"command" => "ls -la"}
            }
          }
        })

      assert {:messages, [update], _state} = Pi.translate_inbound(delta, state)
      assert update["params"]["update"]["sessionUpdate"] == "tool_call_update"
    end

    test "tool_execution_end emits tool result", %{state: state} do
      line =
        Jason.encode!(%{
          "type" => "tool_execution_end",
          "toolCallId" => "tc-1",
          "toolName" => "bash",
          "result" => %{"content" => [%{"type" => "text", "text" => "file1.txt"}]},
          "isError" => false
        })

      assert {:messages, [notification], _state} = Pi.translate_inbound(line, state)
      update = notification["params"]["update"]
      assert update["sessionUpdate"] == "tool_call_update"
      assert update["status"] == "completed"
      assert hd(update["content"])["content"]["text"] == "file1.txt"
    end

    test "edit tool completion emits structured diff when the file changed", %{
      state: state,
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "example.txt")
      File.write!(path, "old\n")

      start =
        Jason.encode!(%{
          "type" => "tool_execution_start",
          "toolCallId" => "edit-1",
          "toolName" => "edit",
          "args" => %{"path" => path, "oldText" => "old"}
        })

      assert {:messages, [_notification], state} = Pi.translate_inbound(start, state)
      File.write!(path, "new\n")

      finish =
        Jason.encode!(%{
          "type" => "tool_execution_end",
          "toolCallId" => "edit-1",
          "result" => %{"content" => [%{"type" => "text", "text" => "updated"}]},
          "isError" => false
        })

      assert {:messages, [notification], _state} = Pi.translate_inbound(finish, state)
      update = notification["params"]["update"]
      assert hd(update["content"])["type"] == "diff"
      assert hd(update["content"])["oldText"] == "old\n"
      assert hd(update["content"])["newText"] == "new\n"
    end

    test "edit snapshots stay inside the host workspace root when the agent reports another cwd",
         %{state: state, tmp_dir: tmp_dir} do
      outside = Path.join(System.tmp_dir!(), "pi_outside_#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)
      path = Path.join(outside, "secret.txt")
      File.write!(path, "secret\n")

      # A misbehaving agent reporting `cwd: "/"` must not widen containment.
      state = %{state | cwd: "/", workspace_root: tmp_dir}

      start =
        Jason.encode!(%{
          "type" => "tool_execution_start",
          "toolCallId" => "edit-outside",
          "toolName" => "edit",
          "args" => %{"path" => path, "oldText" => "secret"}
        })

      assert {:messages, [_notification], state} = Pi.translate_inbound(start, state)
      refute Map.has_key?(state.edit_snapshots, "edit-outside")
      File.write!(path, "changed\n")

      finish =
        Jason.encode!(%{
          "type" => "tool_execution_end",
          "toolCallId" => "edit-outside",
          "result" => %{"content" => [%{"type" => "text", "text" => "updated"}]},
          "isError" => false
        })

      assert {:messages, [notification], _state} = Pi.translate_inbound(finish, state)
      update = notification["params"]["update"]
      refute Enum.any?(update["content"], &(&1["type"] == "diff"))
      refute inspect(update) =~ "secret"
    end

    defp run_edit(state, id, path, target) do
      start =
        Jason.encode!(%{
          "type" => "tool_execution_start",
          "toolCallId" => id,
          "toolName" => "edit",
          "args" => %{"path" => path, "oldText" => "x"}
        })

      {:messages, [_], state} = Pi.translate_inbound(start, state)
      refute Map.has_key?(state.edit_snapshots, id)
      File.write!(target, File.read!(target) <> "changed\n")

      finish =
        Jason.encode!(%{
          "type" => "tool_execution_end",
          "toolCallId" => id,
          "result" => %{"content" => [%{"type" => "text", "text" => "updated"}]},
          "isError" => false
        })

      {:messages, [notification], state} = Pi.translate_inbound(finish, state)
      {notification["params"]["update"]["content"], state}
    end

    defp outside_file(name, contents) do
      dir = Path.join(System.tmp_dir!(), "pi_outside_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      path = Path.join(dir, name)
      File.write!(path, contents)
      path
    end

    test "edit snapshot refuses absolute paths outside the workspace", %{state: state} do
      secret = outside_file("secret.txt", "TOP SECRET\n")
      {content, state} = run_edit(state, "edit-abs", secret, secret)
      refute Enum.any?(content || [], &(&1["type"] == "diff"))
      refute inspect(content) =~ "TOP SECRET"
      assert state.edit_snapshots == %{}
    end

    test "edit snapshot refuses relative traversal outside the workspace", %{
      state: state,
      tmp_dir: tmp_dir
    } do
      secret = outside_file("secret.txt", "TOP SECRET\n")
      rel = Path.relative_to(secret, tmp_dir, force: true)
      assert String.starts_with?(rel, "..")
      {content, _state} = run_edit(state, "edit-rel", rel, secret)
      refute inspect(content) =~ "TOP SECRET"
    end

    test "edit snapshot refuses symlinks escaping the workspace", %{
      state: state,
      tmp_dir: tmp_dir
    } do
      secret = outside_file("secret.txt", "TOP SECRET\n")
      File.mkdir_p!(tmp_dir)
      link = Path.join(tmp_dir, "link.txt")
      :ok = File.ln_s(secret, link)
      {content, _state} = run_edit(state, "edit-link", "link.txt", secret)
      refute inspect(content) =~ "TOP SECRET"
    end

    test "edit snapshot skips files above the size cap", %{state: state, tmp_dir: tmp_dir} do
      File.mkdir_p!(tmp_dir)
      path = Path.join(tmp_dir, "big.txt")
      File.write!(path, :binary.copy("a", 1_048_577))
      {content, state} = run_edit(state, "edit-big", path, path)
      refute Enum.any?(content || [], &(&1["type"] == "diff"))
      assert state.edit_snapshots == %{}
    end
  end

  describe "extension UI interop" do
    test "select requests round-trip through ACP permission choices", %{state: state} do
      state = %{state | session_id: "s1"}

      event = %{
        "type" => "extension_ui_request",
        "id" => "ui-1",
        "method" => "select",
        "title" => "Choose a target",
        "options" => ["staging", "production"],
        "internal" => "must not cross the ACP boundary"
      }

      assert {:messages, [request], state} =
               Pi.translate_inbound(Jason.encode!(event), state)

      assert request["method"] == "session/request_permission"

      assert Enum.map(request["params"]["options"], & &1["optionId"]) == [
               "choice-0",
               "choice-1"
             ]

      assert request["params"]["toolCall"]["toolCallId"] == "pi-ui-ui-1"

      assert request["params"]["toolCall"]["rawInput"] == %{
               "method" => "select",
               "title" => "Choose a target",
               "options" => ["staging", "production"]
             }

      response = %{
        "id" => request["id"],
        "result" => %{
          "outcome" => %{"outcome" => "selected", "optionId" => "choice-1"}
        }
      }

      assert {:ok, data, state} = Pi.translate_outbound(response, state)

      assert decode_one(data) == %{
               "type" => "extension_ui_response",
               "id" => "ui-1",
               "value" => "production"
             }

      assert state.pending_extension_ui == %{}
    end

    test "unsupported input UI always receives a cancellation response", %{state: state} do
      state = %{state | session_id: "s1"}

      event = %{
        "type" => "extension_ui_request",
        "id" => "ui-input",
        "method" => "input",
        "message" => "Secret?"
      }

      assert {:messages_and_write, [notice], data, _state} =
               Pi.translate_inbound(Jason.encode!(event), state)

      assert get_in(notice, ["params", "update", "content", "text"]) =~ "not supported"

      assert decode_one(data) == %{
               "type" => "extension_ui_response",
               "id" => "ui-input",
               "cancelled" => true
             }
    end
  end

  describe "translate_inbound/2 — skip/ignore" do
    test "empty lines are skipped", %{state: state} do
      assert {:skip, ^state} = Pi.translate_inbound("", state)
    end

    test "non-JSON lines are skipped", %{state: state} do
      assert {:skip, ^state} = Pi.translate_inbound("not json", state)
    end

    test "lifecycle events are skipped", %{state: state} do
      for type <- ["agent_start", "turn_start", "turn_end", "message_start", "message_end"] do
        line = Jason.encode!(%{"type" => type})
        assert {:skip, _state} = Pi.translate_inbound(line, state)
      end
    end
  end

  # Correlation ids come from `System.unique_integer([:positive, :monotonic])`,
  # which is VM-global, so in an async suite another test can mint between two
  # of these requests. Absolute values and even consecutiveness are therefore
  # not safe to assert; strictly ascending is, because the counter is monotonic,
  # and it is what catches a refactor that binds the requests out of order.
  defp ascending_rpc_ids(requests) do
    numbers = Enum.map(requests, fn %{"id" => "pi-" <> n} -> String.to_integer(n) end)
    numbers == Enum.sort(numbers) and length(Enum.uniq(numbers)) == length(numbers)
  end

  defp decode_many(data) do
    data
    |> IO.iodata_to_binary()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp decode_one(data), do: data |> decode_many() |> List.first()

  defp response_line(id, command, data) do
    Jason.encode!(%{
      "type" => "response",
      "id" => id,
      "command" => command,
      "success" => true,
      "data" => data
    })
  end

  defp switch_ready_state(state) do
    %{
      state
      | session_id: "s1",
        thinking_level: "high",
        available_thinking_levels: ["off", "medium", "high"],
        current_model_id: "anthropic/claude-sonnet-4",
        available_models: [
          %{"modelId" => "anthropic/claude-sonnet-4", "name" => "anthropic/Claude Sonnet 4"},
          %{"modelId" => "anthropic/claude-opus-4", "name" => "anthropic/Claude Opus 4"},
          %{"modelId" => "openai/gpt-5.1", "name" => "openai/GPT-5.1"}
        ]
    }
  end

  # The request that moves the adapter from s1 to s2 (or closes s1).
  defp session_change("session/new", ctx),
    do: %{"method" => "session/new", "id" => 70, "params" => %{"cwd" => ctx.tmp_dir}}

  defp session_change("session/close", _ctx),
    do: %{"method" => "session/close", "id" => 70, "params" => %{"sessionId" => "s1"}}

  defp session_change(method, ctx) do
    file = Path.join(ctx.session_dir, "s2.jsonl")
    File.write!(file, "")

    File.write!(
      ctx.session_map_path,
      Jason.encode!(%{
        "version" => 1,
        "sessions" => %{
          "s2" => %{"sessionId" => "s2", "cwd" => ctx.tmp_dir, "sessionFile" => file}
        }
      })
    )

    %{"method" => method, "id" => 70, "params" => %{"sessionId" => "s2", "cwd" => ctx.tmp_dir}}
  end

  # s1 switches to gpt-5.1; Pi answers, so the adapter writes the refresh,
  # and s1 asks for claude-opus-4 while that refresh is outstanding.
  defp refresh_with_waiting_switch(state) do
    pi = fake_pi()

    assert {:messages_and_write, _, first, state} =
             Pi.translate_outbound(set_model_request("openai/gpt-5.1"), state)

    {[level_event, switch_reply], pi} = fake_pi_answer(decode_many(first), pi)
    assert {:skip, state} = Pi.translate_inbound(Jason.encode!(level_event), state)

    assert {:skip_and_write, refresh, state} =
             Pi.translate_inbound(Jason.encode!(switch_reply), state)

    assert {:messages_and_write, _, "", state} =
             Pi.translate_outbound(set_model_request("anthropic/claude-opus-4"), state)

    {refresh, state, pi}
  end

  defp reject_with_switch_outstanding(:switch_reply_first, setup, state, pi, ctx, outcome) do
    {state, pi, []} = settle_fake_pi(state, pi, :oldest_first)

    assert {:messages_and_write, [_error], refresh, state} =
             reject_session_setup(setup, state, ctx, outcome)

    drive_fake_pi(refresh, state, pi)
  end

  defp reject_with_switch_outstanding(:rejection_first, setup, state, pi, ctx, outcome) do
    assert {:messages, [_error], state} = reject_session_setup(setup, state, ctx, outcome)
    settle_fake_pi(state, pi, :oldest_first)
  end

  defp change_failure_message(:rejected), do: "Session file is locked"
  defp change_failure_message(:cancelled), do: "Pi cancelled the session change"

  defp feed_without_effect(data, state, pi, label) do
    {replies, _pi} = fake_pi_answer(decode_many(data), pi)

    Enum.reduce(replies, state, fn reply, state ->
      assert {:skip, state} = Pi.translate_inbound(Jason.encode!(reply), state),
             "#{label}: a reply acted while the session change was pending"

      state
    end)
  end

  # Pi rejects the session change, or an extension cancels it; the rest of the
  # setup group is never sent.
  defp reject_session_setup(setup, state, _ctx, outcome \\ :rejected) do
    assert [%{"type" => type} = change] = decode_many(setup)
    assert type in ["new_session", "switch_session"]
    Pi.translate_inbound(Jason.encode!(change_failure(change, outcome)), state)
  end

  defp change_failure(change, :rejected) do
    %{
      "type" => "response",
      "id" => change["id"],
      "command" => change["type"],
      "success" => false,
      "error" => "Session file is locked"
    }
  end

  # An extension vetoed the change: Pi answers success, but stays put.
  defp change_failure(change, :cancelled) do
    %{
      "type" => "response",
      "id" => change["id"],
      "command" => change["type"],
      "success" => true,
      "data" => %{"cancelled" => true}
    }
  end

  # Pi confirms the session change, then answers the setup group for s2.
  defp finish_session_setup(setup, state, ctx) do
    {[_change | followups], state} = confirm_session_change(setup, state)
    answer_session_setup(followups, state, ctx)
  end

  defp answer_session_setup(requests, state, ctx) do
    data = %{
      "new_session" => %{},
      "switch_session" => %{},
      "get_messages" => %{"messages" => []},
      "get_state" => %{
        "sessionId" => "s2",
        "sessionFile" => Path.join(ctx.session_dir, "s2.jsonl"),
        "cwd" => ctx.tmp_dir,
        "thinkingLevel" => "off",
        "model" => %{"provider" => "anthropic", "id" => "claude-sonnet-4"}
      },
      "get_available_models" => %{
        "models" => [
          %{"provider" => "anthropic", "id" => "claude-sonnet-4"},
          %{"provider" => "anthropic", "id" => "claude-opus-4"},
          %{"provider" => "openai", "id" => "gpt-5.1"}
        ]
      },
      "get_available_thinking_levels" => %{"levels" => ["off", "high"]},
      "get_commands" => %{"commands" => []}
    }

    Enum.reduce(requests, {state, []}, fn request, {state, messages} ->
      line = response_line(request["id"], request["type"], Map.fetch!(data, request["type"]))

      case Pi.translate_inbound(line, state) do
        {:skip, state} -> {state, messages}
        {:messages, new, state} -> {state, messages ++ new}
      end
    end)
  end

  defp cancel_request(acp_id),
    do: %{"method" => "$/cancel_request", "params" => %{"requestId" => acp_id}}

  defp set_model_request(model_id) do
    %{"method" => "session/set_model", "params" => %{"sessionId" => "s1", "modelId" => model_id}}
  end

  # A fake Pi RPC process. Like Pi, it dispatches each input line without
  # awaiting the previous one, and set_model finishes only after an
  # asynchronous auth check, so anything read alongside set_model is answered
  # first and describes the model Pi is leaving.
  defp fake_pi do
    %{
      model: %{"provider" => "anthropic", "id" => "claude-sonnet-4"},
      level: "high",
      levels: ["off", "medium", "high"],
      models: %{
        "openai/gpt-5.1" => %{level: "low", levels: ["off", "minimal", "low"]},
        "anthropic/claude-opus-4" => %{level: "xhigh", levels: ~w(off low medium high xhigh)}
      },
      reject_set_model: nil,
      thinking_levels_command?: true,
      # With hold_switches?, set_model requests stay unanswered until
      # settle_fake_pi/3 finishes them, in the order the test picks.
      hold_switches?: false,
      held: [],
      applied: []
    }
  end

  defp fake_pi_answer(requests, pi) do
    {switches, others} = Enum.split_with(requests, &(&1["type"] == "set_model"))

    if pi.hold_switches? do
      {replies, pi} = Enum.flat_map_reduce(others, pi, &fake_pi_reply/2)
      {replies, %{pi | held: pi.held ++ switches}}
    else
      Enum.flat_map_reduce(others ++ switches, pi, &fake_pi_reply/2)
    end
  end

  # Finishes the held set_model requests one at a time, feeding Pi's output
  # to the adapter and anything the adapter writes back to Pi.
  defp settle_fake_pi(state, pi, order, messages \\ []) do
    case pi.held do
      [] ->
        {state, pi, messages}

      held ->
        request = if order == :newest_first, do: List.last(held), else: hd(held)
        {replies, pi} = fake_pi_reply(request, %{pi | held: List.delete(held, request)})
        {state, pi, messages} = feed_fake_pi_output(replies, state, pi, messages)
        settle_fake_pi(state, pi, order, messages)
    end
  end

  defp fake_pi_reply(%{"type" => "set_model"} = request, %{reject_set_model: nil} = pi) do
    key = "#{request["provider"]}/#{request["modelId"]}"
    %{level: level, levels: levels} = Map.fetch!(pi.models, key)
    model = %{"provider" => request["provider"], "id" => request["modelId"]}
    pi = %{pi | model: model, level: level, levels: levels, applied: pi.applied ++ [key]}

    {[
       %{"type" => "thinking_level_changed", "level" => level},
       fake_pi_response(request, true, %{"data" => model})
     ], pi}
  end

  defp fake_pi_reply(%{"type" => "set_model"} = request, pi),
    do: {[fake_pi_response(request, false, %{"error" => pi.reject_set_model})], pi}

  defp fake_pi_reply(%{"type" => "get_state"} = request, pi) do
    data = %{"thinkingLevel" => pi.level, "model" => pi.model, "sessionId" => "s1"}
    {[fake_pi_response(request, true, %{"data" => data})], pi}
  end

  defp fake_pi_reply(
         %{"type" => "get_available_thinking_levels"} = request,
         %{thinking_levels_command?: false} = pi
       ) do
    error = "Unknown command: get_available_thinking_levels"
    {[fake_pi_response(request, false, %{"error" => error})], pi}
  end

  defp fake_pi_reply(%{"type" => "get_available_thinking_levels"} = request, pi),
    do: {[fake_pi_response(request, true, %{"data" => %{"levels" => pi.levels}})], pi}

  defp fake_pi_reply(%{"type" => "set_thinking_level", "level" => level} = request, pi) do
    events =
      if level == pi.level,
        do: [],
        else: [%{"type" => "thinking_level_changed", "level" => level}]

    {events ++ [fake_pi_response(request, true, %{})], %{pi | level: level}}
  end

  # A fake Pi that holds several sessions. Like Pi, it answers each line as it
  # reads it, except new_session/switch_session, which replace the session
  # only after asynchronous steps: lines read meanwhile describe the session
  # Pi is leaving.
  defp session_pi(ctx) do
    session = fn id, level, levels, model, messages ->
      {id,
       %{
         level: level,
         levels: levels,
         model: model,
         file: Path.join(ctx.session_dir, "#{id}.jsonl"),
         messages: messages
       }}
    end

    %{
      cwd: ctx.tmp_dir,
      active: "s1",
      pending_change: nil,
      sessions:
        Map.new([
          session.(
            "s1",
            "high",
            ["off", "medium", "high"],
            %{"provider" => "anthropic", "id" => "claude-sonnet-4"},
            [%{"role" => "user", "content" => "from s1"}]
          ),
          session.(
            "s2",
            "low",
            ["off", "minimal", "low"],
            %{"provider" => "openai", "id" => "gpt-5.1"},
            [%{"role" => "user", "content" => "from s2"}]
          ),
          session.(
            "fresh",
            "xhigh",
            ~w(off low medium high xhigh),
            %{"provider" => "anthropic", "id" => "claude-opus-4"},
            []
          )
        ])
    }
  end

  defp session_pi_answer(requests, pi) do
    Enum.flat_map_reduce(requests, pi, fn
      %{"type" => "switch_session", "sessionPath" => path} = request, pi ->
        {[], %{pi | pending_change: {request, Path.basename(path, ".jsonl")}}}

      %{"type" => "new_session"} = request, pi ->
        {[], %{pi | pending_change: {request, "fresh"}}}

      request, pi ->
        {[session_pi_reply(request, pi)], pi}
    end)
  end

  defp session_setup_request("session/new", acp_id, ctx), do: session_change_new(acp_id, ctx)

  defp session_setup_request(method, acp_id, ctx),
    do: %{session_change(method, ctx) | "id" => acp_id}

  defp result_state_and_messages({:messages, messages, state}), do: {state, messages}

  defp result_state_and_messages({:messages_and_write, messages, _data, state}),
    do: {state, messages}

  # Answers the switch the adapter sent to return Pi to the previous session.
  defp settle_session_change_restore(state) do
    Enum.reduce(Map.keys(state.restoring_session_changes), state, fn id, state ->
      assert {:skip, state} =
               Pi.translate_inbound(response_line(id, "switch_session", %{}), state)

      state
    end)
  end

  # Pi finally answers a change whose setup the client cancelled; returns what
  # the adapter sends once the held model work is released.
  defp answer_cancelled_change(:succeeded, change, state) do
    # Pi switched after all: the adapter sends it back to s1 first.
    assert {:skip_and_write, back, state} =
             Pi.translate_inbound(response_line(change["id"], change["type"], %{}), state)

    assert [%{"type" => "switch_session", "sessionPath" => s1_file} = restore] =
             decode_many(back)

    assert s1_file == state.session_file

    assert {:skip_and_write, next, _state} =
             Pi.translate_inbound(response_line(restore["id"], "switch_session", %{}), state)

    next
  end

  defp answer_cancelled_change(outcome, change, state) do
    assert {:skip_and_write, next, _state} =
             Pi.translate_inbound(Jason.encode!(change_failure(change, outcome)), state)

    next
  end

  defp reply_steps(:queries_first), do: [:queries, :restore]
  defp reply_steps(:restore_first), do: [:restore, :queries]

  defp with_session_file(state, ctx),
    do: %{state | session_file: Path.join(ctx.session_dir, "s1.jsonl")}

  defp session_change_new(acp_id, ctx),
    do: %{"method" => "session/new", "id" => acp_id, "params" => %{"cwd" => ctx.tmp_dir}}

  defp outbound_writes({:ok, :skip, state}), do: {state, "", []}
  defp outbound_writes({:ok, data, state}) when is_binary(data), do: {state, data, []}

  # Like session_pi_answer/2, but several changes can be pending at once and
  # queries are held until the test lets Pi read them.
  defp overlap_pi_receive(data, pi) do
    Enum.reduce(decode_many(data), pi, fn
      %{"type" => "switch_session", "sessionPath" => path} = request, pi ->
        %{pi | pending_change: pi.pending_change ++ [{request, Path.basename(path, ".jsonl")}]}

      %{"type" => "new_session"} = request, pi ->
        %{pi | pending_change: pi.pending_change ++ [{request, "fresh"}]}

      request, pi ->
        %{pi | held_queries: pi.held_queries ++ [request]}
    end)
  end

  # Finishes one pending change, then, as the worst case, every other pending
  # change before Pi reads the queries the adapter sent meanwhile.
  defp settle_overlap_pi(state, %{pending_change: [], held_queries: []} = pi, _order, messages),
    do: {state, pi, messages}

  defp settle_overlap_pi(state, %{pending_change: []} = pi, order, messages) do
    replies = Enum.map(pi.held_queries, &session_pi_reply(&1, pi))
    {state, pi, messages} = feed_overlap_pi(replies, state, %{pi | held_queries: []}, messages)
    settle_overlap_pi(state, pi, order, messages)
  end

  defp settle_overlap_pi(state, pi, order, messages) do
    {request, target} =
      change =
      if order == :newest_first, do: List.last(pi.pending_change), else: hd(pi.pending_change)

    reply = fake_pi_response(request, true, %{"data" => %{"cancelled" => false}})
    pi = %{pi | active: target, pending_change: List.delete(pi.pending_change, change)}
    {state, pi, messages} = feed_overlap_pi([reply], state, pi, messages)
    settle_overlap_pi(state, pi, order, messages)
  end

  defp feed_overlap_pi(replies, state, pi, messages) do
    Enum.reduce(replies, {state, pi, messages}, fn reply, {state, pi, messages} ->
      case Pi.translate_inbound(Jason.encode!(reply), state) do
        {:skip, state} ->
          {state, pi, messages}

        {:messages, new, state} ->
          {state, pi, messages ++ new}

        {:skip_and_write, data, state} ->
          {state, overlap_pi_receive(data, pi), messages}

        {:messages_and_write, new, data, state} ->
          {state, overlap_pi_receive(data, pi), messages ++ new}
      end
    end)
  end

  defp finish_session_pi_change(%{pending_change: {request, target}} = pi) do
    reply = fake_pi_response(request, true, %{"data" => %{"cancelled" => false}})
    {reply, %{pi | active: target, pending_change: nil}}
  end

  defp session_pi_reply(%{"type" => type} = request, pi) do
    session = pi.sessions[pi.active]

    data =
      case type do
        "get_state" ->
          %{
            "sessionId" => pi.active,
            "sessionFile" => session.file,
            "cwd" => pi.cwd,
            "thinkingLevel" => session.level,
            "model" => session.model
          }

        "get_available_models" ->
          %{"models" => Enum.map(pi.sessions, fn {_id, s} -> s.model end) |> Enum.uniq()}

        "get_available_thinking_levels" ->
          %{"levels" => session.levels}

        "get_messages" ->
          %{"messages" => session.messages}

        "get_commands" ->
          %{"commands" => []}
      end

    fake_pi_response(request, true, %{"data" => data})
  end

  defp drive_session_pi(replies, state, pi, messages \\ []) do
    Enum.reduce(replies, {state, pi, messages}, fn reply, {state, pi, messages} ->
      case Pi.translate_inbound(Jason.encode!(reply), state) do
        {:skip, state} ->
          {state, pi, messages}

        {:messages, new, state} ->
          {state, pi, messages ++ new}

        {:skip_and_write, data, state} ->
          {replies, pi} = session_pi_answer(decode_many(data), pi)
          drive_session_pi(replies, state, pi, messages)

        {:messages_and_write, new, data, state} ->
          {replies, pi} = session_pi_answer(decode_many(data), pi)
          drive_session_pi(replies, state, pi, messages ++ new)
      end
    end)
  end

  defp fake_pi_response(request, success, fields) do
    Map.merge(
      %{
        "type" => "response",
        "id" => request["id"],
        "command" => request["type"],
        "success" => success
      },
      fields
    )
  end

  # Feeds what the adapter wrote to the fake Pi, and Pi's output back to the
  # adapter, until the adapter stops writing.
  defp drive_fake_pi(data, state, pi, messages \\ []) do
    {replies, pi} = fake_pi_answer(decode_many(data), pi)
    feed_fake_pi_output(replies, state, pi, messages)
  end

  defp feed_fake_pi_output(replies, state, pi, messages) do
    Enum.reduce(replies, {state, pi, messages}, fn reply, {state, pi, messages} ->
      case Pi.translate_inbound(Jason.encode!(reply), state) do
        {:skip, state} -> {state, pi, messages}
        {:messages, new, state} -> {state, pi, messages ++ new}
        {:skip_and_write, more, state} -> drive_fake_pi(more, state, pi, messages)
        {:messages_and_write, new, more, state} -> drive_fake_pi(more, state, pi, messages ++ new)
      end
    end)
  end

  # Pi answers the session change, and the adapter writes the rest of the
  # setup group. Returns every request of the group, in emission order.
  defp confirm_session_change(data, state, reply \\ %{}) do
    assert [%{"type" => type, "id" => id} = change] = decode_many(data)
    assert type in ["new_session", "switch_session"]

    assert {:skip_and_write, followups, state} =
             Pi.translate_inbound(response_line(id, type, reply), state)

    {[change | decode_many(followups)], state}
  end

  defp respond(state, id, command, data) do
    assert {:skip, state} = Pi.translate_inbound(response_line(id, command, data), state)
    state
  end

  defp write_session(session_dir, id, cwd, first_prompt, name) do
    file = Path.join(session_dir, "#{id}.jsonl")

    lines =
      [
        %{"type" => "session", "id" => id, "cwd" => cwd, "timestamp" => "2026-01-01T00:00:00Z"},
        %{
          "type" => "message",
          "timestamp" => "2026-01-01T00:00:01Z",
          "message" => %{"role" => "user", "content" => first_prompt}
        },
        if(name,
          do: %{"type" => "session_info", "name" => name, "timestamp" => "2026-01-01T00:00:02Z"}
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join("\n", &Jason.encode!/1)

    File.write!(file, lines <> "\n")
  end
end
