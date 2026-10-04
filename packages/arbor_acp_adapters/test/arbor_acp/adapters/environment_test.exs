defmodule Arbor.ACP.Adapters.EnvironmentTest do
  use ExUnit.Case, async: true
  alias Arbor.ACP.AdapterSupport.Subprocess
  alias Arbor.ACP.Adapters.{ClaudeSDK, Codex, Pi, ZCode}

  test "first-use optional environment callbacks load before policy is applied" do
    adapter = Arbor.ACP.Test.EnvironmentFirstUse
    assert Code.ensure_loaded?(adapter)
    :code.purge(adapter)
    assert :code.delete(adapter)
    refute function_exported?(adapter, :environment_defaults, 1)
    refute function_exported?(adapter, :env, 1)

    env =
      Subprocess.safe_env([environment_policy: :inherit], adapter)
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    assert env["FIRST_USE_CREDENTIAL"] == false
    assert env["FIRST_USE_OVERRIDE"] == ~c"loaded"
  end

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
