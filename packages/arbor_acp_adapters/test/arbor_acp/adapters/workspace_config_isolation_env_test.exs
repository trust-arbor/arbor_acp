defmodule Arbor.ACP.Adapters.WorkspaceConfigIsolationEnvTest do
  @moduledoc """
  Security regressions that have to mutate process environment (`PATH` and
  `PI_CODING_AGENT_DIR`). Kept `async: false` so they cannot race other cases.
  """

  use ExUnit.Case, async: false

  alias Arbor.ACP.AdapterSupport.Subprocess
  alias Arbor.ACP.Adapters.Pi
  alias Arbor.ACP.Adapters.Pi.Settings

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    File.write!(
      Path.join(tmp_dir, ".pi/settings.json") |> tap(&File.mkdir_p!(Path.dirname(&1))),
      Jason.encode!(%{"quietStartup" => true, "model" => "stolen-model"})
    )

    %{cwd: tmp_dir}
  end

  test "an inherited PI_CODING_AGENT_DIR does not become Settings.agent_dir", %{cwd: cwd} do
    inherited = Path.join(Path.dirname(cwd), "inherited-pi-#{System.unique_integer([:positive])}")
    File.mkdir_p!(inherited)

    File.write!(
      Path.join(inherited, "settings.json"),
      Jason.encode!(%{"quietStartup" => true, "model" => "inherited-model"})
    )

    previous = System.get_env("PI_CODING_AGENT_DIR")
    System.put_env("PI_CODING_AGENT_DIR", inherited)

    on_exit(fn ->
      if previous,
        do: System.put_env("PI_CODING_AGENT_DIR", previous),
        else: System.delete_env("PI_CODING_AGENT_DIR")
    end)

    home = env_string(child_env([cwd: cwd], Pi)["PI_CODING_AGENT_DIR"])
    assert Settings.agent_dir(cwd: cwd) == home
    refute Settings.agent_dir(cwd: cwd) == Path.expand(inherited)
    refute home == Path.expand(inherited)

    settings = Settings.load(cwd, [])
    refute settings["quietStartup"]
    refute settings["model"] == "inherited-model"
    refute settings["model"] == "stolen-model"
  end

  test "does not launch a Pi executable that lives inside the workspace", %{cwd: cwd} do
    workspace_pi = Path.join(cwd, "pi")
    File.write!(workspace_pi, "#!/bin/sh\necho stolen\n")
    File.chmod!(workspace_pi, 0o755)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", cwd <> ":" <> previous_path)

    on_exit(fn -> System.put_env("PATH", previous_path) end)

    case Pi.cli_command(cwd: cwd) do
      {:error, _reason} ->
        :ok

      {cmd, _args} ->
        resolved = resolve_cli(cmd)
        refute resolved == Path.expand(workspace_pi)
        refute workspace_path?(resolved, cwd)
    end

    {explicit, _args} = Pi.cli_command(cwd: cwd, cli_path: workspace_pi)
    assert Path.expand(explicit) == Path.expand(workspace_pi)
  end

  test "an inherited PI_CODING_AGENT_SESSION_DIR is the session dir the child sees", %{cwd: cwd} do
    session_dir =
      Path.join(Path.dirname(cwd), "inherited-pi-sessions-#{System.unique_integer([:positive])}")

    File.mkdir_p!(session_dir)

    previous = System.get_env("PI_CODING_AGENT_SESSION_DIR")
    System.put_env("PI_CODING_AGENT_SESSION_DIR", session_dir)

    on_exit(fn ->
      if previous,
        do: System.put_env("PI_CODING_AGENT_SESSION_DIR", previous),
        else: System.delete_env("PI_CODING_AGENT_SESSION_DIR")
    end)

    opts = [cwd: cwd, environment_policy: :inherit]
    {:ok, state} = Pi.init(opts)

    assert Path.expand(state.session_dir) == Path.expand(session_dir)

    assert env_string(child_env(opts, Pi)["PI_CODING_AGENT_SESSION_DIR"]) ==
             Path.expand(session_dir)
  end

  defp child_env(opts, adapter) do
    opts
    |> Subprocess.safe_env(adapter)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp env_string(value) when is_list(value), do: List.to_string(value)
  defp env_string(value) when is_binary(value), do: value
  defp env_string(_value), do: nil

  defp resolve_cli(cmd) when is_binary(cmd) do
    cond do
      Path.type(cmd) == :absolute -> Path.expand(cmd)
      true -> System.find_executable(cmd) || cmd
    end
  end

  defp workspace_path?(path, cwd) when is_binary(path) do
    expanded = Path.expand(path)
    prefix = Path.expand(cwd) <> "/"
    expanded == Path.expand(cwd) or String.starts_with?(expanded, prefix)
  end

  defp workspace_path?(_path, _cwd), do: false
end
