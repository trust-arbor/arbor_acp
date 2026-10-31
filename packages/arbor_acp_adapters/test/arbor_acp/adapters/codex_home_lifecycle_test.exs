defmodule Arbor.ACP.Adapters.CodexHomeLifecycleTest do
  use ExUnit.Case, async: true
  alias Arbor.ACP.Adapters.Codex
  import Arbor.ACP.TestHelpers, only: [wait_until: 1]

  test "closing the last thread retains the private home until the connection owner exits" do
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        {:ok, state} = Codex.init(cwd: File.cwd!())
        home = state.opts[:codex_home]
        File.write!(Path.join(home, "connection-data"), "keep")

        {:ok, data, state} =
          Codex.translate_outbound(
            %{"id" => 1, "method" => "session/new", "params" => %{"cwd" => File.cwd!()}},
            state
          )

        native = data |> IO.iodata_to_binary() |> Jason.decode!()

        {:messages, _, state} =
          Codex.translate_inbound(
            Jason.encode!(%{"id" => native["id"], "result" => %{"thread" => %{"id" => "t"}}}),
            state
          )

        {:messages_and_write, _, _, state} =
          Codex.translate_outbound(
            %{"method" => "session/close", "params" => %{"sessionId" => "t"}},
            state
          )

        send(
          parent,
          {:thread_closed, home, File.read(Path.join(home, "connection-data")),
           Codex.env(state.opts)["CODEX_HOME"], state.sessions}
        )

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:thread_closed, home, {:ok, "keep"}, home, %{}}, 1_000
    assert File.dir?(home)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    assert :ok = wait_until(fn -> not File.exists?(home) end)
  end
end
