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

    test "session/close answers its prompts as cancelled and clears runtime state", %{
      state: state
    } do
      state = %{
        state
        | session_id: "s1",
          pending_prompt: %{acp_id: 1, msg_id: "msg-1", cancel_requested: false},
          prompt_queue:
            PromptQueue.new()
            |> PromptQueue.enqueue(%{acp_id: 2, message: "queued", images: [], params: %{}})
      }

      assert {:messages_and_reply_and_write, cancelled, %{}, abort, new_state} =
               Pi.translate_outbound(
                 %{"method" => "session/close", "params" => %{"sessionId" => "s1"}},
                 state
               )

      assert Enum.map(cancelled, &{&1["id"], &1["result"]}) == [
               {1, %{"stopReason" => "cancelled"}},
               {2, %{"stopReason" => "cancelled"}}
             ]

      assert [%{"type" => "abort"}] = decode_many(abort)
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
      assert state.op_in_flight == nil
      assert state.op_queue == []

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
        assert state.op_in_flight == nil
        assert state.op_queue == []
        assert state.desynced == nil

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
      assert after_many.op_in_flight.rpc_id == first_id

      assert [%{fields: queued_fields}] = after_many.op_queue

      assert queued_fields == %{
               "provider" => "anthropic",
               "modelId" => "claude-opus-4"
             }

      # Once Pi answers, only the latest waiting switch is sent.
      {state, pi, _messages} = settle_fake_pi(after_many, pi, :oldest_first)
      assert pi.applied == ["openai/gpt-5.1", "anthropic/claude-opus-4"]
      assert state.current_model_id == "anthropic/claude-opus-4"
      assert state.op_queue == []
    end

    test "a switch requested during a load's queries waits and reaches s1 if the load fails",
         ctx do
      state = with_session_file(switch_ready_state(ctx.state), ctx)

      assert {:ok, setup, state} =
               Pi.translate_outbound(session_change("session/load", ctx), state)

      {[_change | queries], state} = confirm_session_change(setup, state)

      # Pi is already on s2, but the adapter still serves s1: nothing is sent.
      assert {:messages_and_write, _, "", state} =
               Pi.translate_outbound(set_model_request("anthropic/claude-opus-4"), state)

      models = Enum.find(queries, &(&1["type"] == "get_available_models"))

      failure =
        Jason.encode!(%{
          "type" => "response",
          "id" => models["id"],
          "command" => "get_available_models",
          "success" => false,
          "error" => "catalog unavailable"
        })

      assert {:messages_and_write, [_error], back, state} = Pi.translate_inbound(failure, state)
      assert [%{"type" => "switch_session"} = restore] = decode_many(back)

      assert {:skip_and_write, next, _state} =
               Pi.translate_inbound(response_line(restore["id"], "switch_session", %{}), state)

      assert [%{"type" => "set_model", "modelId" => "claude-opus-4"}] = decode_many(next)
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

    # Every Pi request that reads or changes the session is a serialized
    # operation: a setup, a switch back, a model switch, or a usage request
    # waits for the one in flight. The ordered fake Pi records the order in
    # which it applied the asynchronous ones.
    for method <- ["session/load", "session/resume", "session/new"] do
      @op_method method
      test "a #{method} waits for a model switch in flight to finish first", ctx do
        {state, pi} = {ordered_state(ctx), ordered_pi(ctx)}
        {state, pi, _} = outbound(state, pi, set_model_request("openai/gpt-5.1"))
        {state, pi, _} = outbound(state, pi, session_change(@op_method, ctx))
        assert [%{"type" => "set_model"}] = pi.held, "the setup did not wait for set_model"

        {state, pi, messages} = ordered_drive(state, pi)
        target = if @op_method == "session/new", do: "fresh", else: "s2"
        assert pi.applied == [{:model, "s1", "openai/gpt-5.1"}, {:session, target}]
        assert state.session_id == target
        assert %{"result" => _} = Enum.find(messages, &(&1["id"] == 70))
      end
    end

    for outcome <- [:rejected, :cancelled] do
      @change_outcome outcome
      test "a switch for s1 queued behind a #{outcome} setup is applied before the next setup",
           ctx do
        {state, pi} = {ordered_state(ctx), ordered_pi(ctx)}
        {state, pi, _} = outbound(state, pi, session_change("session/load", ctx))
        {state, pi, _} = outbound(state, pi, set_model_request("openai/gpt-5.1"))
        {state, pi, _} = outbound(state, pi, session_change_new(71, ctx))
        assert [%{"type" => "switch_session"}] = pi.held

        pi = refuse_next(pi, "switch_session", @change_outcome)
        {state, pi, messages} = ordered_drive(state, pi)

        assert pi.applied == [{:model, "s1", "openai/gpt-5.1"}, {:session, "fresh"}],
               "#{@change_outcome}: s1's switch was not applied to s1 before the next setup"

        assert %{"error" => _} = Enum.find(messages, &(&1["id"] == 70))
        assert %{"result" => %{"sessionId" => "fresh"}} = Enum.find(messages, &(&1["id"] == 71))
        assert state.session_id == "fresh"
      end
    end

    test "a switch for s1 queued behind a setup that establishes s2 is dropped", ctx do
      {state, pi} = {ordered_state(ctx), ordered_pi(ctx)}
      {state, pi, _} = outbound(state, pi, session_change("session/load", ctx))
      {state, pi, _} = outbound(state, pi, set_model_request("anthropic/claude-opus-4"))
      {state, pi, _messages} = ordered_drive(state, pi)

      assert pi.applied == [{:session, "s2"}]
      assert state.session_id == "s2"
      assert state.current_model_id == "openai/gpt-5.1"
      assert state.op_queue == []
    end

    for late <- [:rejected, :cancelled, :succeeded] do
      @late_outcome late
      test "a load cancelled before Pi answers lets Pi's late answer decide (#{late})", ctx do
        {state, pi} = {ordered_state(ctx), ordered_pi(ctx)}
        {state, pi, _} = outbound(state, pi, session_change("session/load", ctx))
        {state, pi, _} = outbound(state, pi, set_model_request("openai/gpt-5.1"))

        assert {:messages, [error], state} = Pi.translate_outbound(cancel_request(70), state)
        assert error["error"]["code"] == -32_800
        assert [%{"type" => "switch_session"}] = pi.held

        pi =
          if @late_outcome == :succeeded,
            do: pi,
            else: refuse_next(pi, "switch_session", @late_outcome)

        {state, pi, _messages} = ordered_drive(state, pi)

        expected =
          if @late_outcome == :succeeded,
            do: [{:session, "s2"}, {:session, "s1"}, {:model, "s1", "openai/gpt-5.1"}],
            else: [{:model, "s1", "openai/gpt-5.1"}]

        assert pi.applied == expected
        assert state.session_id == "s1"
        assert pi.active == "s1"
        assert state.op_in_flight == nil
      end
    end

    for order <- [:queries_first, :switch_back_first] do
      @reply_order order
      test "a load cancelled after its change succeeded returns Pi to s1 (#{order})", ctx do
        {state, pi} = {ordered_state(ctx), %{ordered_pi(ctx) | hold_queries?: true}}
        before = Map.take(state, [:session_id, :session_file, :cwd, :workspace_root])
        {state, pi, _} = outbound(state, pi, session_change("session/load", ctx))
        {state, pi, []} = finish_held(state, pi)
        assert length(pi.held_queries) == 5

        {state, pi, [error]} = outbound(state, pi, cancel_request(70))
        assert error["error"]["code"] == -32_800
        assert [%{"type" => "switch_session"}] = pi.held

        {state, pi, messages} =
          case_order(@reply_order, state, pi, &answer_held_queries/2, &finish_held/2)

        assert messages == []
        assert pi.applied == [{:session, "s2"}, {:session, "s1"}]
        assert Map.take(state, [:session_id, :session_file, :cwd, :workspace_root]) == before
        assert state.op_in_flight == nil
      end
    end

    test "session/close during a switch back keeps the next setup waiting for it", ctx do
      {state, pi} = {ordered_state(ctx), %{ordered_pi(ctx) | hold_queries?: true}}
      {state, pi, _} = outbound(state, pi, session_change("session/load", ctx))
      {state, pi, []} = finish_held(state, pi)
      {state, pi, [_error]} = outbound(state, pi, cancel_request(70))
      assert [%{"type" => "switch_session"}] = pi.held

      {state, pi, _} = outbound(state, pi, session_change_new(71, ctx))
      close = %{"method" => "session/close", "id" => 72, "params" => %{"sessionId" => "s1"}}
      assert {:reply, %{}, state} = Pi.translate_outbound(close, state)
      assert [%{"type" => "switch_session"}] = pi.held, "the next setup did not wait"

      {state, pi, messages} = ordered_drive(state, pi)
      assert pi.applied == [{:session, "s2"}, {:session, "s1"}, {:session, "fresh"}]
      assert %{"result" => %{"sessionId" => "fresh"}} = Enum.find(messages, &(&1["id"] == 71))
      assert state.session_id == pi.active
    end

    test "a refused switch back stops the adapter claiming the session Pi left", ctx do
      {state, pi} = {ordered_state(ctx), %{ordered_pi(ctx) | hold_queries?: true}}
      {state, pi, _} = outbound(state, pi, session_change("session/load", ctx))
      {state, pi, []} = finish_held(state, pi)
      {state, pi, [_error]} = outbound(state, pi, cancel_request(70))
      pi = refuse_next(pi, "switch_session", :rejected)
      {state, pi, _messages} = ordered_drive(state, pi)
      assert pi.active == "s2"

      prompt = %{
        "method" => "session/prompt",
        "id" => 80,
        "params" => %{"sessionId" => "s1", "prompt" => [%{"type" => "text", "text" => "hi"}]}
      }

      for request <- [
            prompt,
            set_model_request("openai/gpt-5.1"),
            %{
              "method" => "session/set_mode",
              "params" => %{"sessionId" => "s1", "modeId" => "low"}
            },
            %{
              "method" => "session/set_config_option",
              "params" => %{"sessionId" => "s1", "configId" => "auto_retry", "value" => false}
            }
          ] do
        assert {:error, reason, _state} = Pi.translate_outbound(request, state),
               "the adapter still accepted #{request["method"]} for the session Pi left"

        assert reason =~ "Pi is not on session s1"
      end

      assert state.desynced == %{session_id: "s1"}

      # A new session resynchronises the adapter.
      {state, pi, _} = outbound(state, pi, session_change_new(81, ctx))
      {state, _pi, _messages} = ordered_drive(state, pi)
      assert state.desynced == nil
      assert state.session_id == "fresh"

      assert {:ok, data, _state} =
               Pi.translate_outbound(put_in(prompt, ["params", "sessionId"], "fresh"), state)

      assert [%{"type" => "prompt"}] = decode_many(data)
    end

    test "setups fail at once while a cancelled change is unanswered", ctx do
      {state, pi} = {ordered_state(ctx), ordered_pi(ctx)}
      {state, pi, _} = outbound(state, pi, session_change("session/load", ctx))
      assert {:ok, :pending, state} = Pi.translate_outbound(session_change_new(71, ctx), state)

      assert {:messages, messages, state} = Pi.translate_outbound(cancel_request(70), state)

      assert [
               %{"id" => 70, "error" => %{"code" => -32_800}},
               %{
                 "id" => 71,
                 "error" => %{"message" => "Pi has not answered an earlier session change"}
               }
             ] = messages

      assert {:error, "Pi has not answered an earlier session change", state} =
               Pi.translate_outbound(session_change_new(72, ctx), state)

      # Once Pi answers, setups run again.
      pi = refuse_next(pi, "switch_session", :rejected)
      {state, pi, _} = ordered_drive(state, pi)
      {state, pi, _} = outbound(state, pi, session_change_new(73, ctx))
      assert [%{"type" => "new_session"}] = pi.held
      {state, _pi, messages} = ordered_drive(state, pi)
      assert %{"result" => %{"sessionId" => "fresh"}} = Enum.find(messages, &(&1["id"] == 73))
      assert state.session_id == "fresh"
    end

    test "failed setups leave no bookkeeping behind", ctx do
      fail_setups = fn count ->
        Enum.reduce(1..count, {ordered_state(ctx), ordered_pi(ctx)}, fn n, {state, pi} ->
          request = %{session_change("session/load", ctx) | "id" => 100 + n}
          {state, pi, _} = outbound(state, pi, request)

          # Alternately the change is refused, or it succeeds and a query fails.
          pi =
            if rem(n, 2) == 0,
              do: refuse_next(pi, "switch_session", :rejected),
              else: refuse_next(pi, "get_available_models", :rejected)

          {state, pi, _messages} = ordered_drive(state, pi)
          {state, pi}
        end)
      end

      {after_two, pi_two} = fail_setups.(2)
      {after_many, pi_many} = fail_setups.(20)

      assert Map.drop(after_many, [:rpc_counter]) == Map.drop(after_two, [:rpc_counter])
      assert after_many.pending_controls == %{}
      assert after_many.control_groups == %{}
      assert {after_many.op_in_flight, after_many.op_queue} == {nil, []}
      assert pi_two.active == "s1" and pi_many.active == "s1"
    end

    # A prompt runs in the session Pi is on; while a session change runs, Pi
    # may already be on the other session.
    for phase <- [:setup_running, :setup_waiting, :switch_back_running] do
      @change_phase phase
      test "a prompt sent while a session change is #{phase} fails at once", ctx do
        {state, pi} = {ordered_state(ctx), %{ordered_pi(ctx) | hold_queries?: true}}
        {state, pi} = enter_change_phase(@change_phase, state, pi, ctx)
        writes_before = pi.requests

        prompt = %{
          "method" => "session/prompt",
          "id" => 80,
          "params" => %{"sessionId" => "s1", "prompt" => [%{"type" => "text", "text" => "hi"}]}
        }

        assert {:error, reason, state} = Pi.translate_outbound(prompt, state),
               "#{@change_phase}: the prompt reached Pi during the session change"

        assert reason =~ "Pi is changing sessions"
        assert pi.requests == writes_before

        # Once the change settles, prompts for the current session run.
        {state, _pi, _messages} = ordered_drive(state, pi)
        current = put_in(prompt, ["params", "sessionId"], state.session_id)
        assert {:ok, data, _state} = Pi.translate_outbound(current, state)
        assert [%{"type" => "prompt"}] = decode_many(data)
      end
    end

    test "a setup answers the running prompt, queued prompts and commands as cancelled", ctx do
      {state, pi} = {ordered_state(ctx), ordered_pi(ctx)}
      text = fn text -> [%{"type" => "text", "text" => text}] end

      prompt =
        &%{
          "method" => "session/prompt",
          "id" => &1,
          "params" => %{"sessionId" => "s1", "prompt" => &2}
        }

      assert {:ok, _data, state} = Pi.translate_outbound(prompt.(60, text.("working")), state)

      assert {:messages, _notices, state} =
               Pi.translate_outbound(prompt.(61, text.("queued")), state)

      state = %{state | pending_prompt: nil}
      assert {:ok, _data, state} = Pi.translate_outbound(prompt.(62, text.("/session")), state)
      state = %{state | pending_prompt: %{acp_id: 60, msg_id: "msg-1", cancel_requested: false}}

      {state, pi, messages} = outbound(state, pi, session_change("session/load", ctx))

      assert Enum.map(messages, &{&1["id"], &1["result"]}) == [
               {60, %{"stopReason" => "cancelled"}},
               {62, %{"stopReason" => "cancelled"}},
               {61, %{"stopReason" => "cancelled"}}
             ]

      assert ["abort", "switch_session"] = pi.requests
      assert state.pending_prompt == nil
      assert state.control_groups |> Map.values() |> Enum.map(& &1.type) == [:session_load]
    end

    test "a setup with only a prompt command running asks Pi to abort nothing", ctx do
      {state, pi} = {ordered_state(ctx), ordered_pi(ctx)}

      command = %{
        "method" => "session/prompt",
        "id" => 62,
        "params" => %{
          "sessionId" => "s1",
          "prompt" => [%{"type" => "text", "text" => "/session"}]
        }
      }

      assert {:ok, _data, state} = Pi.translate_outbound(command, state)
      {_state, pi, messages} = outbound(state, pi, session_change("session/load", ctx))

      assert [%{"id" => 62, "result" => %{"stopReason" => "cancelled"}}] = messages
      assert pi.requests == ["switch_session"]
    end

    test "a prompt after a refused setup waits for the turn the setup aborted", ctx do
      state = %{
        ordered_state(ctx)
        | pending_prompt: %{acp_id: 9, msg_id: "msg-9", cancel_requested: false}
      }

      assert {:messages_and_write, [%{"id" => 9, "result" => %{"stopReason" => "cancelled"}}],
              data, state} = Pi.translate_outbound(session_change("session/load", ctx), state)

      assert [%{"type" => "abort"}, %{"type" => "switch_session", "id" => switch_id}] =
               decode_many(data)

      # An extension refuses the switch, so Pi stays on s1 and its aborted turn
      # settles later.
      refused = response_line(switch_id, "switch_session", %{"cancelled" => true})

      assert {:messages, [%{"id" => 70, "error" => _}], state} =
               Pi.translate_inbound(refused, state)

      assert state.session_id == "s1"

      prompt = %{
        "method" => "session/prompt",
        "id" => 10,
        "params" => %{"sessionId" => "s1", "prompt" => [%{"type" => "text", "text" => "next"}]}
      }

      assert {:messages, _queued_notices, state} = Pi.translate_outbound(prompt, state)

      # The aborted turn's late output answers nothing and streams nothing.
      delta = %{
        "type" => "message_update",
        "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "old"}
      }

      for event <- [delta, %{"type" => "agent_end", "messages" => []}] do
        assert {:skip, state} = Pi.translate_inbound(Jason.encode!(event), state)
        assert state.pending_prompt == nil
      end

      assert {:messages_and_write, _started_notices, next, state} =
               Pi.translate_inbound(Jason.encode!(%{"type" => "agent_settled"}), state)

      assert [%{"type" => "prompt", "message" => "next"}] = decode_many(next)

      assert {:messages, [%{"id" => 10, "result" => %{"stopReason" => "end_turn"}}], _state} =
               Pi.translate_inbound(Jason.encode!(%{"type" => "agent_settled"}), state)
    end

    test "a prompt a setup cancelled sends no usage request", ctx do
      {state, pi} = {ordered_state(ctx), ordered_pi(ctx)}
      state = %{state | pending_prompt: %{acp_id: 9, msg_id: "msg-9", cancel_requested: false}}
      {state, pi, [cancelled]} = outbound(state, pi, session_change("session/load", ctx))

      assert cancelled == %{
               "jsonrpc" => "2.0",
               "id" => 9,
               "result" => %{"stopReason" => "cancelled"}
             }

      # The cancelled prompt's late agent_end and agent_settled change nothing.
      for event <- [%{"type" => "agent_end", "messages" => []}, %{"type" => "agent_settled"}] do
        assert {:skip, state} = Pi.translate_inbound(Jason.encode!(event), state)
        assert state.op_queue == []
      end

      {state, pi, _messages} = ordered_drive(state, pi)
      refute "get_session_stats" in pi.requests
      assert pi.requests |> Enum.take(1) == ["abort"]
      assert state.session_id == "s2"
    end

    test "a usage request in flight is answered before a setup starts", ctx do
      {state, pi} = {ordered_state(ctx), ordered_pi(ctx)}
      state = %{state | pending_prompt: %{acp_id: 9, msg_id: "msg-9", cancel_requested: false}}

      assert {:skip_and_write, stats, state} =
               Pi.translate_inbound(
                 Jason.encode!(%{"type" => "agent_end", "messages" => []}),
                 state
               )

      # The setup cancels the running prompt and waits for the usage request.
      assert {:messages_and_write, [%{"id" => 9, "result" => %{"stopReason" => "cancelled"}}],
              abort, state} = Pi.translate_outbound(session_change("session/load", ctx), state)

      assert [%{"type" => "abort"}] = decode_many(abort)
      [%{"id" => stats_id}] = decode_many(stats)

      usage =
        response_line(stats_id, "get_session_stats", %{
          "contextUsage" => %{"tokens" => 120, "contextWindow" => 200_000}
        })

      assert {:messages_and_write, [update], setup, _state} = Pi.translate_inbound(usage, state)
      assert update["params"]["sessionId"] == "s1"
      assert update["params"]["update"]["sessionUpdate"] == "usage_update"
      assert [%{"type" => "switch_session"}] = decode_many(setup)
      _ = pi
    end

    test "Pi exiting during a setup fails waiting setups and holds nothing", ctx do
      {state, pi} = {ordered_state(ctx), ordered_pi(ctx)}
      {state, pi, _} = outbound(state, pi, session_change("session/load", ctx))
      {state, _pi, _} = outbound(state, pi, set_model_request("openai/gpt-5.1"))
      assert {:ok, :pending, state} = Pi.translate_outbound(session_change_new(71, ctx), state)

      assert {:messages, messages, state} =
               Pi.handle_adapter_message({nil, {:exit_status, 1}}, state)

      assert Enum.map(messages, & &1["id"]) == [70, 71]
      assert {state.op_in_flight, state.op_queue} == {nil, []}

      assert {:messages_and_write, _, data, _state} =
               Pi.translate_outbound(set_model_request("openai/gpt-5.1"), state)

      assert [%{"type" => "set_model"}] = decode_many(data)
    end

    test "cancelling another request leaves a running setup alone", ctx do
      {state, pi} = {ordered_state(ctx), ordered_pi(ctx)}
      {state, _pi, _} = outbound(state, pi, session_change("session/load", ctx))
      assert {:ok, :skip, ^state} = Pi.translate_outbound(cancel_request(71), state)
      assert %{type: :setup, acp_id: 70} = state.op_in_flight
    end

    test "a waiting setup the client cancels never starts", ctx do
      {state, pi} = {ordered_state(ctx), ordered_pi(ctx)}
      {state, pi, _} = outbound(state, pi, session_change("session/load", ctx))
      assert {:ok, :pending, state} = Pi.translate_outbound(session_change_new(71, ctx), state)

      assert {:messages, [%{"id" => 71, "error" => %{"code" => -32_800}}], state} =
               Pi.translate_outbound(cancel_request(71), state)

      {state, pi, messages} = ordered_drive(state, pi)
      assert pi.applied == [{:session, "s2"}]
      refute Enum.any?(messages, &(&1["id"] == 71))
      assert state.session_id == "s2"
    end

    for closer <- ["session/close", "session/delete"] do
      @closer closer
      test "a setup waiting behind a running one starts when it ends, across #{closer}", ctx do
        {state, pi} = {ordered_state(ctx), ordered_pi(ctx)}
        {state, pi, _} = outbound(state, pi, session_change("session/load", ctx))
        assert {:ok, :pending, state} = Pi.translate_outbound(session_change_new(71, ctx), state)

        close = %{"method" => @closer, "id" => 72, "params" => %{"sessionId" => "s1"}}
        assert {:reply, %{}, state} = Pi.translate_outbound(close, state)

        {state, pi, messages} = ordered_drive(state, pi)
        assert pi.applied == [{:session, "s2"}, {:session, "fresh"}]
        assert %{"result" => %{"sessionId" => "s2"}} = Enum.find(messages, &(&1["id"] == 70))
        assert %{"result" => %{"sessionId" => "fresh"}} = Enum.find(messages, &(&1["id"] == 71))
        assert state.session_id == "fresh"
      end
    end

    # A setup query can still be answered after its setup ended: here the
    # catalog query fails first and get_state is answered later.
    test "a late setup query reply after the setup failed changes nothing", ctx do
      {state, pi} = {ordered_state(ctx), %{ordered_pi(ctx) | hold_queries?: true}}
      {state, pi, _} = outbound(state, pi, session_change("session/load", ctx))
      {state, pi, []} = finish_held(state, pi)
      {get_state, others} = Enum.split_with(pi.held_queries, &(&1["type"] == "get_state"))
      pi = %{pi | held_queries: others} |> refuse_next("get_available_models", :rejected)

      {state, pi, messages} = answer_held_queries(state, pi)
      assert %{"error" => _} = Enum.find(messages, &(&1["id"] == 70))
      {state, pi, _} = ordered_drive(state, pi)
      assert pi.active == "s1"
      before = Map.take(state, [:session_id, :session_file, :thinking_level])

      late =
        response_line(hd(get_state)["id"], "get_state", %{
          "sessionId" => "stale",
          "sessionFile" => Path.join(ctx.session_dir, "stale.jsonl"),
          "thinkingLevel" => "xhigh"
        })

      assert {:skip, state} = Pi.translate_inbound(late, state)
      assert Map.take(state, [:session_id, :session_file, :thinking_level]) == before
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

  describe "outbound_write_failed/3" do
    # Unmanaged, the consumer writes what translate_outbound/2 returns; a
    # failed write is answered with the error, so the adapter forgets the
    # request instead of answering it again later.
    defp prompt_request(id, text),
      do: %{
        "method" => "session/prompt",
        "id" => id,
        "params" => %{"sessionId" => "s1", "prompt" => [%{"type" => "text", "text" => text}]}
      }

    test "a prompt Pi never received is not pending", ctx do
      state = ordered_state(ctx)
      request = prompt_request(5, "hello")
      assert {:ok, _data, state} = Pi.translate_outbound(request, state)
      state = Pi.outbound_write_failed(request, :closed, state)
      assert state.pending_prompt == nil

      # A setup then has nothing to cancel.
      assert {:ok, _change, _state} =
               Pi.translate_outbound(session_change("session/load", ctx), state)
    end

    test "a prompt command Pi never received leaves no group", ctx do
      state = ordered_state(ctx)
      request = prompt_request(6, "/session")
      assert {:ok, _data, state} = Pi.translate_outbound(request, state)
      state = Pi.outbound_write_failed(request, :closed, state)
      assert state.control_groups == %{}
      assert state.pending_controls == %{}
    end

    test "a setup Pi never received restores the previous session", ctx do
      state = ordered_state(ctx)
      request = session_change("session/new", ctx)
      assert {:ok, _data, failed} = Pi.translate_outbound(request, state)
      failed = Pi.outbound_write_failed(request, :closed, failed)

      assert failed.op_in_flight == nil
      assert failed.control_groups == %{}
      assert failed.pending_controls == %{}
      assert {failed.session_id, failed.cwd} == {state.session_id, state.cwd}
    end

    test "a waiting setup whose notices could not be written leaves the queue", ctx do
      state = ordered_state(ctx)

      assert {:ok, _data, state} =
               Pi.translate_outbound(session_change("session/new", ctx), state)

      waiting = session_change_new(71, ctx)
      assert {:ok, :pending, state} = Pi.translate_outbound(waiting, state)
      state = Pi.outbound_write_failed(waiting, :closed, state)
      assert state.op_queue == []
      assert %{type: :setup, acp_id: 70} = state.op_in_flight
    end

    test "only the model switch a request started is retired", ctx do
      state = ordered_state(ctx)

      set_model =
        &%{
          "method" => "session/set_model",
          "id" => &1,
          "params" => %{"sessionId" => "s1", "modelId" => &2}
        }

      first = set_model.(1, "openai/gpt-5.1")
      assert {:messages_and_write, _messages, _data, state} = Pi.translate_outbound(first, state)
      second = set_model.(2, "anthropic/claude-opus-4")
      assert {:messages_and_write, _messages, "", state} = Pi.translate_outbound(second, state)

      # The second switch only waited, so its failed write leaves the first.
      assert %{type: :model_switch, acp_id: 1} =
               Pi.outbound_write_failed(second, :closed, state).op_in_flight

      assert Pi.outbound_write_failed(first, :closed, state).op_in_flight == nil
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

    test "file slash commands expand to prompts", %{state: state, tmp_dir: tmp_dir} = ctx do
      prompts_dir = Path.join([tmp_dir, ".pi", "prompts"])
      File.mkdir_p!(prompts_dir)
      File.write!(Path.join(prompts_dir, "review.md"), "Review $1 and $@")

      msg = %{"method" => "session/new", "id" => 25, "params" => %{"cwd" => tmp_dir}}
      {state, pi, _messages} = outbound(state, ordered_pi(ctx), msg)
      {state, _pi, _messages} = ordered_drive(state, pi)

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
      state = %{
        state
        | session_id: "s1",
          op_in_flight: %{type: :usage, rpc_id: "pi-1", session_id: "s1"}
      }

      assert {:skip, state} =
               Pi.translate_inbound(
                 response_line("pi-1", "get_session_stats", %{
                   "contextUsage" => %{"tokens" => nil, "contextWindow" => 200_000}
                 }),
                 state
               )

      assert state.op_in_flight == nil
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

  # Pi rejects the session change, or an extension cancels it; the rest of the
  # setup group is never sent.
  defp reject_session_setup(setup, state, _ctx, outcome) do
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

  defp with_session_file(state, ctx),
    do: %{state | session_file: Path.join(ctx.session_dir, "s1.jsonl")}

  defp session_change_new(acp_id, ctx),
    do: %{"method" => "session/new", "id" => acp_id, "params" => %{"cwd" => ctx.tmp_dir}}

  defp outbound_writes({:ok, :skip, state}), do: {state, "", []}
  defp outbound_writes({:ok, :pending, state}), do: {state, "", []}
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

  defp enter_change_phase(:setup_running, state, pi, ctx) do
    {state, pi, _} = outbound(state, pi, session_change("session/load", ctx))
    {state, pi}
  end

  defp enter_change_phase(:setup_waiting, state, pi, ctx) do
    {state, pi, _} = outbound(state, pi, set_model_request("openai/gpt-5.1"))
    {state, pi, _} = outbound(state, pi, session_change("session/load", ctx))
    {state, pi}
  end

  defp enter_change_phase(:switch_back_running, state, pi, ctx) do
    {state, pi, _} = outbound(state, pi, session_change("session/load", ctx))
    {state, pi, []} = finish_held(state, pi)
    {state, pi, [_error]} = outbound(state, pi, cancel_request(70))
    {state, pi}
  end

  defp ordered_state(ctx) do
    state = with_session_file(switch_ready_state(ctx.state), ctx)

    %{
      state
      | available_models: [
          %{"modelId" => "anthropic/claude-sonnet-4", "name" => "anthropic/Claude Sonnet 4"},
          %{"modelId" => "anthropic/claude-opus-4", "name" => "anthropic/Claude Opus 4"},
          %{"modelId" => "openai/gpt-5.1", "name" => "openai/GPT-5.1"}
        ]
    }
  end

  # A fake Pi that holds sessions and records, in order, what it applied.
  # set_model, new_session and switch_session finish only when the test lets
  # them, newest first as the worst case; with hold_queries?, reads wait too.
  # Everything else is answered at once from the session active when Pi reads
  # it. refuse_next/3 makes the next request of a type fail.
  defp ordered_pi(ctx) do
    %{
      cwd: ctx.tmp_dir,
      session_dir: ctx.session_dir,
      active: "s1",
      models: %{
        "s1" => "anthropic/claude-sonnet-4",
        "s2" => "openai/gpt-5.1",
        "fresh" => "anthropic/claude-opus-4"
      },
      held: [],
      held_queries: [],
      hold_queries?: false,
      applied: [],
      requests: [],
      refuse: %{}
    }
  end

  defp refuse_next(pi, type, outcome), do: %{pi | refuse: Map.put(pi.refuse, type, outcome)}

  defp outbound(state, pi, request) do
    case Pi.translate_outbound(request, state) do
      {:ok, :skip, state} -> {state, pi, []}
      {:ok, :pending, state} -> {state, pi, []}
      {:ok, data, state} -> ordered_write(data, state, pi, [])
      {:messages, messages, state} -> {state, pi, messages}
      {:messages_and_write, messages, data, state} -> ordered_write(data, state, pi, messages)
      {:reply, _result, state} -> {state, pi, []}
    end
  end

  defp ordered_write(data, state, pi, messages) do
    {replies, pi} = ordered_receive(data, pi)
    ordered_feed(replies, state, pi, messages)
  end

  defp ordered_receive(data, pi) do
    Enum.flat_map_reduce(decode_many(data), pi, fn request, pi ->
      pi = %{pi | requests: pi.requests ++ [request["type"]]}

      cond do
        request["type"] in ["set_model", "new_session", "switch_session"] ->
          {[], %{pi | held: pi.held ++ [request]}}

        request["type"] == "abort" ->
          {[], pi}

        pi.hold_queries? ->
          {[], %{pi | held_queries: pi.held_queries ++ [request]}}

        true ->
          ordered_reply(request, pi)
      end
    end)
  end

  defp ordered_reply(%{"type" => type} = request, pi) do
    case Map.pop(pi.refuse, type) do
      {nil, _refuse} -> ordered_apply(request, pi)
      {outcome, refuse} -> {[change_failure(request, outcome)], %{pi | refuse: refuse}}
    end
  end

  defp ordered_apply(%{"type" => "set_model"} = request, pi) do
    model = "#{request["provider"]}/#{request["modelId"]}"

    {[fake_pi_response(request, true, %{"data" => %{}})],
     %{
       pi
       | models: Map.put(pi.models, pi.active, model),
         applied: pi.applied ++ [{:model, pi.active, model}]
     }}
  end

  defp ordered_apply(%{"type" => type} = request, pi)
       when type in ["new_session", "switch_session"] do
    target =
      if type == "new_session", do: "fresh", else: Path.basename(request["sessionPath"], ".jsonl")

    {[fake_pi_response(request, true, %{"data" => %{"cancelled" => false}})],
     %{pi | active: target, applied: pi.applied ++ [{:session, target}]}}
  end

  defp ordered_apply(%{"type" => type} = request, pi) do
    [provider, id] = String.split(pi.models[pi.active], "/", parts: 2)

    data =
      case type do
        "get_state" ->
          %{
            "sessionId" => pi.active,
            "sessionFile" => Path.join(pi.session_dir, "#{pi.active}.jsonl"),
            "cwd" => pi.cwd,
            "thinkingLevel" => "medium",
            "model" => %{"provider" => provider, "id" => id}
          }

        "get_available_models" ->
          %{
            "models" =>
              for model <- Map.values(pi.models) |> Enum.uniq() do
                [provider, id] = String.split(model, "/", parts: 2)
                %{"provider" => provider, "id" => id}
              end
          }

        "get_available_thinking_levels" ->
          %{"levels" => ~w(off low medium high)}

        "get_messages" ->
          %{"messages" => []}

        "get_commands" ->
          %{"commands" => []}

        "get_session_stats" ->
          %{}
      end

    {[fake_pi_response(request, true, %{"data" => data})], pi}
  end

  defp ordered_feed(replies, state, pi, messages) do
    Enum.reduce(replies, {state, pi, messages}, fn reply, {state, pi, messages} ->
      case Pi.translate_inbound(Jason.encode!(reply), state) do
        {:skip, state} -> {state, pi, messages}
        {:messages, new, state} -> {state, pi, messages ++ new}
        {:skip_and_write, data, state} -> ordered_write(data, state, pi, messages)
        {:messages_and_write, new, data, state} -> ordered_write(data, state, pi, messages ++ new)
      end
    end)
  end

  # Pi finishes a held request: newest first, the worst case for overlap.
  defp finish_held(state, %{held: []} = pi), do: {state, pi, []}

  defp finish_held(state, pi) do
    request = List.last(pi.held)
    {replies, pi} = ordered_reply(request, %{pi | held: List.delete(pi.held, request)})
    ordered_feed(replies, state, pi, [])
  end

  defp answer_held_queries(state, pi) do
    {replies, pi} =
      Enum.flat_map_reduce(pi.held_queries, %{pi | held_queries: []}, &ordered_reply/2)

    ordered_feed(replies, state, pi, [])
  end

  # Lets Pi finish everything, answering reads before finishing held requests.
  defp ordered_drive(state, pi, messages \\ []) do
    cond do
      pi.held_queries != [] ->
        {state, pi, new} = answer_held_queries(state, pi)
        ordered_drive(state, pi, messages ++ new)

      pi.held != [] ->
        {state, pi, new} = finish_held(state, pi)
        ordered_drive(state, pi, messages ++ new)

      true ->
        {state, pi, messages}
    end
  end

  defp case_order(:queries_first, state, pi, queries, held) do
    {state, pi, first} = queries.(state, pi)
    {state, pi, second} = held.(state, pi)
    {state, pi, first ++ second}
  end

  defp case_order(:switch_back_first, state, pi, queries, held) do
    {state, pi, first} = held.(state, pi)
    {state, pi, second} = queries.(state, pi)
    {state, pi, first ++ second}
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
