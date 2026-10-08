defmodule Arbor.ACP.AgentStopTest do
  use ExUnit.Case, async: true

  alias Arbor.ACP.Agent
  alias Arbor.ACP.Agent.Transport.Memory

  defmodule Handler do
    @behaviour Arbor.ACP.Agent.Handler
    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_new_session(_params, _context, state),
      do: {:reply, %{"sessionId" => "stop-test"}, state}

    @impl true
    def handle_prompt(_session, _prompt, _context, state),
      do: {:reply, %{"stopReason" => "end_turn"}, state}
  end

  test "stop accepts a reason and finite options, preserving the options-only call" do
    for stop <- [
          fn agent -> Agent.stop(agent, timeout: 1_000) end,
          fn agent -> Agent.stop(agent, :shutdown, timeout: 1_000) end
        ] do
      peer = start_supervised!({Memory, []}, id: make_ref())
      {:ok, agent} = Agent.start_link(handler: Handler, transport: {:memory, peer})
      Process.unlink(agent)
      monitor = Process.monitor(agent)
      assert :ok = stop.(agent)
      assert_receive {:DOWN, ^monitor, :process, ^agent, reason}
      assert reason in [:normal, :shutdown]
      assert Process.alive?(peer)
      assert :ok = Agent.stop(agent, :normal, timeout: 1_000)
    end
  end

  test "stop rejects unbounded timeouts and oversized reasons before shutdown" do
    peer = start_supervised!({Memory, []})
    agent = start_supervised!({Agent, handler: Handler, transport: {:memory, peer}})
    assert_raise ArgumentError, fn -> Agent.stop(agent, :normal, timeout: :infinity) end
    assert_raise ArgumentError, fn -> Agent.stop(agent, String.duplicate("x", 4_097), []) end
    assert Process.alive?(agent)
  end
end
