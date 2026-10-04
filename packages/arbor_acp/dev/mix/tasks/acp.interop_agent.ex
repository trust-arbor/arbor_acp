defmodule Mix.Tasks.Acp.InteropAgent do
  @moduledoc """
  Runs a minimal stdio ACP agent for cross-language interop tests.

      mix acp.interop_agent
  """

  use Mix.Task

  @shortdoc "Runs a stdio ACP agent for interop testing"

  def run(_args) do
    Mix.Task.run("app.config")
    configure_host_logging()
    Mix.Task.run("app.start")

    Code.eval_string(~S"""
    defmodule AcpInteropAgentHandler do
      @behaviour Arbor.ACP.Agent.Handler

      @impl true
      def init(_opts), do: {:ok, %{sessions: MapSet.new()}}

      @impl true
      def handle_new_session(_params, _ctx, state) do
        session_id = "sess_elixir_interop"
        {:reply, %{"sessionId" => session_id}, %{state | sessions: MapSet.put(state.sessions, session_id)}}
      end

      @impl true
      def handle_prompt(session_id, prompt, ctx, state) do
        text =
          prompt
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("", &Map.get(&1, "text", ""))

        :ok = Arbor.ACP.Agent.agent_message(ctx.agent, session_id, "Hello from ")
        :ok = Arbor.ACP.Agent.agent_message(ctx.agent, session_id, "ExMCP ACP agent: #{text}")

        {:reply, %{"stopReason" => "end_turn"}, state}
      end

      @impl true
      def handle_list_sessions(_params, _ctx, state) do
        sessions =
          Enum.map(state.sessions, fn session_id ->
            %{"sessionId" => session_id, "name" => "Elixir ACP interop session"}
          end)

        {:reply, sessions, state}
      end

      @impl true
      def handle_close_session(session_id, _ctx, state) do
        {:reply, %{}, %{state | sessions: MapSet.delete(state.sessions, session_id)}}
      end

      @impl true
      def handle_cancel(_session_id, _ctx, state) do
        {:reply, %{"stopReason" => "cancelled"}, state}
      end
    end
    """)

    {:ok, agent} =
      Arbor.ACP.Agent.start_link(
        handler: AcpInteropAgentHandler,
        agent_info: %{"name" => "elixir-acp-interop-agent", "version" => "1.0.0"},
        capabilities: %{
          "sessionCapabilities" => %{
            "list" => %{},
            "close" => %{}
          }
        }
      )

    await_agent(agent)
  end

  # This standalone command owns its VM's default logger handler. Preserve
  # its level, formatter and filters while routing diagnostics away from JSON-RPC.
  defp configure_host_logging do
    {:ok, %{module: :logger_std_h} = handler} = :logger.get_handler_config(:default)

    config =
      handler
      |> Map.drop([:id, :module])
      |> Map.update!(:config, &Map.put(&1, :type, :standard_error))

    # Mix app.start restarts Logger, so persist this host-owned boot policy too.
    boot_config =
      config
      |> Map.put(:module, :logger_std_h)
      |> Map.update!(:config, &Map.to_list/1)
      |> Map.to_list()

    Application.put_env(:logger, :default_handler, boot_config)
    :ok = :logger.remove_handler(:default)
    :ok = :logger.add_handler(:default, :logger_std_h, config)
  end

  defp await_agent(agent) do
    ref = Process.monitor(agent)

    receive do
      {:DOWN, ^ref, :process, ^agent, _reason} -> :ok
    end
  end
end
