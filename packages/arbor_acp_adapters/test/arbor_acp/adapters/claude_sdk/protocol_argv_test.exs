defmodule Arbor.ACP.Adapters.ClaudeSDK.ProtocolArgvTest do
  use ExUnit.Case, async: true

  alias Arbor.ACP.Adapters.ClaudeSDK.Protocol

  @uuid "123e4567-e89b-12d3-a456-426614174000"
  @session_uuid "123e4567-e89b-12d3-a456-426614174001"

  describe "value-taking options" do
    # A value starting with `-` would be parsed as another Claude Code flag,
    # e.g. `--mcp-config` starting an arbitrary command (CVE-2026-96620).
    test "reject a value that would be parsed as another flag" do
      for {key, value} <- [
            effort: "-x",
            max_turns: -1,
            max_budget_usd: "-1",
            model: "-x",
            model: ~c"--mcp-config",
            model: :"-x",
            fallback_model: "-x",
            agent: "-x",
            resume_session_at: "-x",
            thinking: "-x",
            max_thinking_tokens: "-x",
            permission_mode: "-x",
            additional_directories: ["/workspace", "-x"],
            additional_directories: "-x",
            mcp_config_path: "-x",
            allowed_tools: ["-x", "Read"],
            disallowed_tools: "-x",
            tools: ["-x"]
          ] do
        assert {:error, {:invalid_option, ^key, "must not start with '-'"}} =
                 Protocol.command([{key, value}]),
               inspect({key, value})
      end
    end

    test "reject a value that is not a string" do
      assert {:error, {:invalid_option, :model, "must be a string"}} =
               Protocol.command(model: %{"name" => "x"})

      assert {:error, {:invalid_option, :allowed_tools, "must be a string"}} =
               Protocol.command(allowed_tools: ["Read", {:bash, "-x"}])
    end

    test "pass ordinary values through unchanged" do
      assert {_cmd, args} =
               Protocol.command(
                 model: "claude-sonnet-4",
                 max_turns: 3,
                 additional_directories: ["/a", "/b"],
                 allowed_tools: ["Read", "Bash(git:*)"]
               )

      assert flag_values(args, "--model") == ["claude-sonnet-4"]
      assert flag_values(args, "--max-turns") == ["3"]
      assert flag_values(args, "--add-dir") == ["/a", "/b"]
      assert flag_values(args, "--allowedTools") == ["Read,Bash(git:*)"]
    end
  end

  describe "Claude session UUIDs" do
    test "a valid UUID for resume still works" do
      assert {_cmd, args} = Protocol.command(resume: @uuid)
      assert flag_values(args, "--resume") == [@uuid]
    end

    test "a valid UUID for session-id still works" do
      assert {_cmd, args} = Protocol.command(session_id: @session_uuid)
      assert flag_values(args, "--session-id") == [@session_uuid]
    end

    test "resume and session-id reject anything but a UUID, including flags" do
      for {key, value} <- [
            resume: "sess_1",
            resume: "-x",
            resume: ~c"--mcp-config",
            session_id: "not-a-uuid",
            session_id: "-x"
          ] do
        assert {:error, {:invalid_option, ^key, "must be a Claude session UUID"}} =
                 Protocol.command([{key, value}]),
               inspect({key, value})
      end
    end
  end

  defp flag_values(args, flag) do
    args
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {^flag, index} -> [Enum.at(args, index + 1)]
      _other -> []
    end)
  end
end
