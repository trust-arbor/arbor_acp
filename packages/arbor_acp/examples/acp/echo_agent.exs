#!/usr/bin/env elixir

# This standalone host routes its own default logger to stderr before loading
# the library; preserve normal levels, formatter and filters.
{:ok, %{module: :logger_std_h} = stdio_logger} = :logger.get_handler_config(:default)

stdio_logger_config =
  stdio_logger
  |> Map.drop([:id, :module])
  |> Map.update!(:config, &Map.put(&1, :type, :standard_error))

# Mix.install may restart Logger; carry the same host routing into that boot.
stdio_logger_boot =
  stdio_logger_config
  |> Map.put(:module, :logger_std_h)
  |> Map.update!(:config, &Map.to_list/1)
  |> Map.to_list()

Application.put_env(:logger, :default_handler, stdio_logger_boot)
:ok = :logger.remove_handler(:default)
:ok = :logger.add_handler(:default, :logger_std_h, stdio_logger_config)

unless Code.ensure_loaded?(Arbor.ACP) do
  Mix.install(
    [
      {:arbor_acp, path: Path.expand("../..", __DIR__)}
    ],
    verbose: false
  )
end

defmodule EchoAgent do
  @behaviour Arbor.ACP.Agent.Handler

  @impl true
  def init(_opts), do: {:ok, %{sessions: %{}}}

  @impl true
  def handle_new_session(params, _ctx, state) do
    session_id = "sess_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    name = Path.basename(params["cwd"] || File.cwd!())

    state = put_in(state, [:sessions, session_id], %{name: name, cwd: params["cwd"]})

    {:reply, %{"sessionId" => session_id}, state}
  end

  @impl true
  def handle_prompt(session_id, prompt, ctx, state) do
    text =
      prompt
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("", &Map.get(&1, "text", ""))

    :ok = Arbor.ACP.Agent.agent_message(ctx.agent, session_id, "Echo agent received: ")
    :ok = Arbor.ACP.Agent.agent_message(ctx.agent, session_id, text)

    {:reply, %{"stopReason" => "end_turn"}, state}
  end

  @impl true
  def handle_cancel(_session_id, _ctx, state) do
    {:reply, %{"stopReason" => "cancelled"}, state}
  end
end

if System.get_env("MCP_ENV") != "test" do
  Arbor.ACP.run_agent(
    handler: EchoAgent,
    agent_info: %{"name" => "ex-mcp-echo-agent", "version" => "1.0.0"},
    capabilities: %{"sessionCapabilities" => %{"close" => true}}
  )
end
