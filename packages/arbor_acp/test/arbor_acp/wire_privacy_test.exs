defmodule Arbor.ACP.WirePrivacyTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Arbor.ACP.{Agent, Client}

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  test "untracked peer-controlled response IDs stay out of logs" do
    secret = "wire-log-secret-#{System.unique_integer([:positive])}"
    frame = Jason.encode!(%{"jsonrpc" => "2.0", "id" => secret, "result" => %{}})

    log =
      capture_log([level: :debug], fn ->
        assert {:noreply, _} =
                 Agent.handle_info({:transport_message, frame}, %Agent{
                   pending_client_requests: %{}
                 })

        assert {:noreply, _} =
                 Client.handle_info({:transport_message, frame}, %Client{pending_requests: %{}})
      end)

    refute log =~ secret
    assert log =~ "unknown client request"
  end
end
