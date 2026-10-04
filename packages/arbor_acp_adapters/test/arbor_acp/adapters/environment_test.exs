defmodule ArborACP.Adapters.EnvironmentTest do
  use ExUnit.Case, async: true
  alias ArborACP.AdapterSupport.Subprocess
  alias ArborACP.Adapters.{ClaudeSDK, Codex, Pi, ZCode}

  test "each bundled adapter clears ambient vendor credentials with inheritance enabled" do
    for adapter <- [ClaudeSDK, Codex, Pi, ZCode] do
      env =
        Subprocess.safe_env([environment_policy: :inherit], adapter)
        |> Map.new(fn {key, value} -> {to_string(key), value} end)

      assert env["OPENAI_API_KEY"] == false
      assert env["ANTHROPIC_API_KEY"] == false
      assert env["PI_API_KEY"] == false
    end
  end

  test "Pi alone accepts the Pi API key and explicit env overrides defaults" do
    opts = [api_key: "pi-key", env: [{"OPENAI_API_KEY", "explicit"}]]

    for adapter <- [ClaudeSDK, Codex, Pi, ZCode] do
      env =
        Subprocess.safe_env(opts, adapter)
        |> Map.new(fn {key, value} -> {to_string(key), value} end)

      assert env["OPENAI_API_KEY"] == ~c"explicit"
      assert env["PI_API_KEY"] == if(adapter == Pi, do: ~c"pi-key", else: false)
    end
  end
end
