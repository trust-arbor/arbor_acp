defmodule Arbor.ACP.Adapters.UtilitySubprocessTest do
  use ExUnit.Case, async: false

  alias Arbor.ACP.Adapters.ClaudeSDK
  alias Arbor.ACP.Adapters.ClaudeSDK.SessionStore
  alias Arbor.ACP.Adapters.Pi.Startup

  @session_id "123e4567-e89b-12d3-a456-426614174003"

  setup do
    directory =
      Path.join(System.tmp_dir!(), "arbor-vendor-capture-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    {physical_directory, 0} = System.cmd("/bin/pwd", ["-P"], cd: directory)
    directory = String.trim(physical_directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  test "Claude logout uses exact arguments, adapter environment and cwd", %{directory: directory} do
    cli =
      script(directory, "claude", """
      printf '%s|%s|%s|%s|%s|%s' "$1" "$2" "$PWD" "$CLAUDE_CODE_ENTRYPOINT" "$UTILITY_VALUE" "${MIX_ENV-unset}" > logout-result
      """)

    {:ok, state} =
      ClaudeSDK.init(cli_path: cli, cwd: directory, env: %{"UTILITY_VALUE" => "literal"})

    state = %{state | gateway_auth: %{"methodId" => "gateway"}}
    assert {:reply, %{}, state} = ClaudeSDK.translate_outbound(logout(), state)
    assert state.gateway_auth == nil

    assert File.read!(Path.join(directory, "logout-result")) ==
             "auth|logout|#{directory}|sdk-ts|literal|unset"
  end

  test "Claude logout reports nonzero status with combined stderr and output overflow", %{
    directory: directory
  } do
    cli = script(directory, "claude", "printf denied >&2; exit 7")
    {:ok, state} = ClaudeSDK.init(cli_path: cli, cwd: directory)
    assert {:error, message, _state} = ClaudeSDK.translate_outbound(logout(), state)
    assert message == "claude auth logout failed with status 7: denied"

    cli = script(directory, "claude", "printf 123456")
    {:ok, state} = ClaudeSDK.init(cli_path: cli, cwd: directory, max_output_bytes: 5)
    assert {:error, message, _state} = ClaudeSDK.translate_outbound(logout(), state)
    assert message =~ ":output_too_large"
  end

  test "Claude logout timeout reaps its command and returns an explicit error", %{
    directory: directory
  } do
    cli = script(directory, "claude", "echo $$ > child-pid; exec /bin/sleep 30")

    {:ok, state} =
      ClaudeSDK.init(
        cli_path: cli,
        cwd: directory,
        timeout: 500,
        cleanup_timeout: 200,
        term_grace: 50
      )

    assert {:error, message, _state} = ClaudeSDK.translate_outbound(logout(), state)
    assert message =~ ":timeout"
    eventually(fn -> not alive?(Path.join(directory, "child-pid")) end)
  end

  test "Pi version and npm update probes share the caller PATH, environment and cwd", %{
    directory: directory
  } do
    script(directory, "pi", "printf 'pi 1.0.0\\n'")

    script(directory, "npm", """
    printf '%s|%s|%s|%s' "$1" "$3" "$PWD" "$UTILITY_VALUE" > npm-result
    printf '2.0.0\n'
    """)

    opts = [update_notice: true, env: %{"PATH" => directory, "UTILITY_VALUE" => "configured"}]
    settings = %{"quietStartup" => true, "_opts" => opts}
    assert Startup.build(directory, settings) == "Update available: Pi 1.0.0 -> 2.0.0"

    assert File.read!(Path.join(directory, "npm-result")) ==
             "view|version|#{directory}|configured"
  end

  test "Pi omits unsuccessful and oversized optional version probes", %{directory: directory} do
    cli = script(directory, "pi", "printf 'pi invalid\\n'; exit 7")
    settings = %{"_opts" => [cli_path: cli, update_notice: false]}
    refute (Startup.build(directory, settings) || "") =~ "Pi "

    script(directory, "pi", "i=0; while [ \"$i\" -lt 70000 ]; do printf x; i=$((i + 1)); done")
    refute (Startup.build(directory, settings) || "") =~ "Pi "
  end

  test "Pi probe timeout reaps a child that ignores output", %{directory: directory} do
    cli = script(directory, "pi", "echo $$ > child-pid; exec /bin/sleep 30")

    settings = %{
      "_opts" => [cli_path: cli, update_notice: false, cleanup_timeout: 200, term_grace: 50]
    }

    refute (Startup.build(directory, settings) || "") =~ "Pi "
    eventually(fn -> not alive?(Path.join(directory, "child-pid")) end)
  end

  test "worktree discovery honors explicit child PATH and map-shaped environment options", %{
    directory: directory
  } do
    workspace = Path.join(directory, "worktree")
    File.mkdir_p!(workspace)
    config = Path.join(directory, "claude-config")
    project = Path.join([config, "projects", SessionStore.project_key(workspace)])
    File.mkdir_p!(project)

    File.write!(
      Path.join(project, "#{@session_id}.jsonl"),
      Jason.encode!(%{"summary" => "from worktree", "cwd" => workspace}) <> "\n"
    )

    script(directory, "git", """
    printf '%s|%s|%s' "$1" "$PWD" "${MIX_ENV-unset}" > git-result
    printf 'worktree %s\n\n' "$UTILITY_TREE"
    """)

    assert {:ok, [session]} =
             SessionStore.list_acp_sessions(%{
               "claudeConfigDir" => config,
               "cwd" => directory,
               "env" => %{"PATH" => directory, "UTILITY_TREE" => workspace}
             })

    assert session["sessionId"] == @session_id
    assert File.read!(Path.join(directory, "git-result")) == "worktree|#{directory}|unset"
  end

  defp logout, do: %{"id" => 1, "method" => "logout", "params" => %{}}

  defp script(directory, name, body) do
    path = Path.join(directory, name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  defp eventually(predicate, attempts \\ 100)

  defp eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end

  defp eventually(_predicate, 0), do: flunk("utility did not stop")

  defp alive?(marker) do
    pid = marker |> File.read!() |> String.trim()
    {_output, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
    status == 0
  end
end
