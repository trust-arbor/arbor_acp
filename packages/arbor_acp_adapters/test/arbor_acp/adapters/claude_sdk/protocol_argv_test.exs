defmodule Arbor.ACP.Adapters.ClaudeSDK.ProtocolArgvTest do
  use ExUnit.Case, async: true

  alias Arbor.ACP.Adapters.ClaudeSDK.Protocol

  @uuid "123e4567-e89b-12d3-a456-426614174000"
  @session_uuid "123e4567-e89b-12d3-a456-426614174001"
  @dash "-x"

  describe "value-taking flags never emit a bare leading-dash argv entry" do
    test "resume: \"-x\" never produces a bare \"-x\" argv entry" do
      refute_bare_dash_value(Protocol.command(resume: @dash), @dash)
    end

    test "resume_session_at: \"-x\" never produces a bare \"-x\" argv entry" do
      refute_bare_dash_value(Protocol.command(resume_session_at: @dash), @dash)
    end

    test "session_id: \"-x\" never produces a bare \"-x\" argv entry" do
      refute_bare_dash_value(Protocol.command(session_id: @dash), @dash)
    end

    test "model: \"-x\" never produces a bare \"-x\" argv entry" do
      refute_bare_dash_value(Protocol.command(model: @dash), @dash)
    end

    test "additional_directories: [\"-x\"] never produces a bare \"-x\" argv entry" do
      refute_bare_dash_value(Protocol.command(additional_directories: [@dash]), @dash)
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

    test "rejects a non-UUID resume value" do
      assert {:error, {:invalid_option, :resume, message}} = Protocol.command(resume: "sess_1")
      assert message =~ "UUID"
    end

    test "rejects a non-UUID session-id value" do
      assert {:error, {:invalid_option, :session_id, message}} =
               Protocol.command(session_id: "not-a-uuid")

      assert message =~ "UUID"
    end
  end

  defp refute_bare_dash_value({:error, _reason}, _value), do: :ok

  defp refute_bare_dash_value({_cmd, args}, value) when is_list(args) do
    refute value in args
  end

  defp refute_bare_dash_value(other, _value) do
    flunk("expected an argv tuple or an error, got: #{inspect(other)}")
  end

  defp flag_values(args, flag) do
    equals = flag <> "="

    args
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {^flag, index} ->
        [Enum.at(args, index + 1)]

      {arg, _index} when is_binary(arg) ->
        if String.starts_with?(arg, equals) do
          [String.replace_prefix(arg, equals, "")]
        else
          []
        end

      {_arg, _index} ->
        []
    end)
  end
end
