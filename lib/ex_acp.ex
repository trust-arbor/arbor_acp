defmodule ExACP do
  @moduledoc """
  Facade for the Agent Client Protocol (ACP).

  ACP lets clients control coding agents over stdio using JSON-RPC 2.0 — the same
  wire format as MCP. Many coding agents speak ACP natively (Gemini CLI,
  OpenCode, Qwen Code, etc.), and Elixir applications can expose native ACP
  agents with `ExACP.Agent`.

  ## Quick Start

      {:ok, client} = ExACP.start_client(command: ["gemini", "--acp"])
      {:ok, %{"sessionId" => sid}} = ExACP.Client.new_session(client, "/my/project")
      {:ok, %{"stopReason" => _}} = ExACP.Client.prompt(client, sid, "Fix the bug")

      {:ok, agent} = ExACP.start_agent(handler: MyApp.AgentHandler)

  ## Options

  See `ExACP.Client` and `ExACP.Agent` for the full option lists.
  """

  alias ExACP.Agent
  alias ExACP.Client

  @doc """
  Starts an ACP client connected to an agent subprocess.

  Shorthand for `ExACP.Client.start_link/1`.
  """
  @spec start_client(keyword()) :: GenServer.on_start()
  def start_client(opts) do
    Client.start_link(opts)
  end

  @doc """
  Starts an ACP agent runtime.

  Shorthand for `ExACP.Agent.start_link/1`.
  """
  @spec start_agent(keyword()) :: GenServer.on_start()
  def start_agent(opts) do
    Agent.start_link(opts)
  end

  @doc """
  Starts an ACP agent runtime and blocks until it exits.

  Shorthand for `ExACP.Agent.run/1`.
  """
  @spec run_agent(keyword()) :: :ok | {:error, any()}
  def run_agent(opts) do
    Agent.run(opts)
  end
end
