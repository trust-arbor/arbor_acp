defmodule Arbor.ACP.StdioHostLoggingTest do
  use ExUnit.Case, async: false

  test "default stdio aliases and embedded devices preserve host logger state" do
    {stdout, _stderr, 0} =
      child(~S"""
      Logger.configure(level: :info)
      Application.put_env(:arbor_acp, :stdio_mode, false)
      :ok = :logger.add_primary_filter(:host_filter, {fn event, _ -> event end, :host_state})
      {:ok, device} = StringIO.open("")
      before = {Logger.level(), :logger.get_primary_config(), :logger.get_handler_config(),
        Application.get_env(:logger, :level), Application.get_env(:arbor_acp, :stdio_mode)}
      for output <- [:stdio, :standard_io, device] do
        {:ok, transport} = Arbor.ACP.Agent.Transport.Stdio.connect(input: device, output: output)
        ^output = transport.output
        after_connect = {Logger.level(), :logger.get_primary_config(), :logger.get_handler_config(),
          Application.get_env(:logger, :level), Application.get_env(:arbor_acp, :stdio_mode)}
        true = after_connect == before
        :ok = Arbor.ACP.Agent.Transport.Stdio.close(transport)
      end
      true = Process.alive?(device)
      IO.puts("host-config-preserved")
      """)

    assert stdout == "host-config-preserved\n"
  end

  test "legacy configure remains exported with its explicit global suppression behavior" do
    {stdout, _stderr, 0} =
      child(~S"""
      true = Code.ensure_loaded?(Arbor.ACP.Internal.StdioLoggerConfig)
      true = function_exported?(Arbor.ACP.Internal.StdioLoggerConfig, :configure, 0)
      :ok = Arbor.ACP.Internal.StdioLoggerConfig.configure()
      true = Application.get_env(:arbor_acp, :stdio_mode)
      :emergency = Logger.level()
      :emergency = Application.get_env(:logger, :level)
      :emergency = :logger.get_primary_config().level
      IO.puts("legacy-policy-retained")
      """)

    assert stdout == "legacy-policy-retained\n"
  end

  test "standalone echo host preserves normal logs on stderr and JSON-RPC on stdout" do
    input =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => 1,
          "clientCapabilities" => %{},
          "clientInfo" => %{"name" => "logging-host", "version" => "1"}
        }
      }) <> "\n"

    {stdout, stderr, 0} =
      child(
        ~S"""
        Logger.configure(level: :info)
        Code.require_file("examples/acp/echo_agent.exs")
        :info = Logger.level()
        require Logger
        Logger.info("host-info-after-agent")
        Logger.flush()
        """,
        input
      )

    frames = stdout |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.map(frames, & &1["id"]) == [1]
    assert Enum.all?(frames, &Map.has_key?(&1, "result"))
    assert stderr =~ "host-info-after-agent"
    refute stdout =~ "host-info-after-agent"
  end

  test "standalone Mix host carries stderr routing through Logger restart" do
    input =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => 1,
          "clientCapabilities" => %{},
          "clientInfo" => %{"name" => "logging-host", "version" => "1"}
        }
      }) <> "\n"

    {stdout, stderr, 0} =
      child(
        ~S"""
        Mix.start()
        Code.require_file("mix.exs")
        Mix.Task.run("app.config", ["--no-compile", "--no-deps-check"])
        host_level = Application.get_env(:logger, :level, Logger.level())
        Mix.Tasks.Acp.InteropAgent.run([])
        ^host_level = Logger.level()
        require Logger
        Logger.info("host-info-after-mix-agent")
        Logger.flush()
        """,
        input
      )

    [frame] = stdout |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert frame["id"] == 1 and Map.has_key?(frame, "result")
    assert stderr =~ "host-info-after-mix-agent"
    refute stdout =~ "host-info-after-mix-agent"
  end

  defp child(script, input \\ "") do
    directory =
      Path.join(System.tmp_dir!(), "arbor-acp-host-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    script_path = Path.join(directory, "host.exs")
    input_path = Path.join(directory, "input")
    error_path = Path.join(directory, "stderr")
    File.write!(script_path, script)
    File.write!(input_path, input)
    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])

    {stdout, code} =
      System.cmd(
        "sh",
        [
          "-c",
          ~s(exec "$@" < "$HOST_INPUT" 2> "$HOST_STDERR"),
          "host",
          System.find_executable("elixir")
        ] ++ paths ++ [script_path],
        env: [
          {"MIX_ENV", "test"},
          {"HOST_INPUT", input_path},
          {"HOST_STDERR", error_path},
          {"MCP_ENV", "logging-host"}
        ]
      )

    stderr = File.read!(error_path)
    assert code == 0, "host exit #{code}\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
    {stdout, stderr, code}
  end
end
