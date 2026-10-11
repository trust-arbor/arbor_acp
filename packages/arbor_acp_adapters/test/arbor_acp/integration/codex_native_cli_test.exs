defmodule Arbor.ACP.Integration.CodexNativeCLITest do
  use ExUnit.Case, async: false
  alias Arbor.ACP.Adapters.Codex.Native
  alias Arbor.ACP.Test.CodexNative, as: Harness
  @moduletag :external
  @moduletag :interop_codex_native
  @moduletag timeout: 90_000

  test "pinned native reads and concurrent requests preserve correlation" do
    Harness.with_client("native_reads", fn %{client: client, root: root} ->
      assert is_list(Harness.request!(client, "model/list")["data"])
      assert is_list(Harness.request!(client, "thread/loaded/list")["data"])

      results =
        Task.async_stream(
          1..12,
          fn number ->
            cwd = Path.join(root, "worker-#{number}")
            File.mkdir_p!(cwd)
            thread = Harness.start_thread!(client, cwd)["thread"]
            {Path.basename(cwd), Path.basename(thread["cwd"]), thread["id"]}
          end,
          max_concurrency: 4,
          timeout: 40_000
        )
        |> Enum.to_list()

      assert Enum.all?(results, fn {:ok, {expected, actual, id}} ->
               expected == actual and is_binary(id)
             end)

      assert length(Enum.uniq_by(results, fn {:ok, {_, _, id}} -> id end)) == 12
      %{concurrent_calls: 12}
    end)
  end

  test "native thread lifecycle exposes complete events and releases the thread" do
    Harness.with_client("native_lifecycle", fn %{client: client, root: root} ->
      assert :ok = Native.subscribe(client)
      started = Harness.start_thread!(client, root, %{"ephemeral" => false})
      thread = started["thread"]["id"]
      assert is_binary(thread)

      assert_receive {:acp_extension_notification, "_arbor/codex/event",
                      %{
                        "event" => %{
                          "method" => "thread/started",
                          "params" => %{"thread" => %{"id" => ^thread}}
                        }
                      }},
                     5_000

      read =
        Harness.request!(client, "thread/read", %{"threadId" => thread, "includeTurns" => false})

      assert read["thread"]["id"] == thread

      # Codex does not persist a resumable rollout until a turn has started.
      assert {:error, %{"code" => -32600, "message" => message}} =
               Native.request(client, "thread/resume", %{
                 "threadId" => thread,
                 "excludeTurns" => true
               })

      assert String.starts_with?(message, "no rollout found for thread id ")

      assert is_binary(
               Harness.request!(client, "thread/unsubscribe", %{"threadId" => thread})["status"]
             )

      assert :ok = Native.unsubscribe(client)
      %{lifecycle_calls: 4, native_event_verified: true}
    end)
  end

  test "native error objects and owned handshake rejection are returned without disconnecting" do
    Harness.with_client("native_errors", fn %{client: client} ->
      for {method, params} <- [
            {"arborNativeUnknownMethod", %{}},
            {"thread/read", %{"threadId" => []}}
          ] do
        result = Native.request(client, method, params)

        assert match?(
                 {:error, %{"code" => code, "message" => message}}
                 when is_integer(code) and is_binary(message),
                 result
               )
      end

      assert {:error, %{"message" => "native_handshake_owned_by_adapter"}} =
               Native.request(client, "initialize")

      assert is_list(Harness.request!(client, "thread/loaded/list")["data"])
      %{error_cases: 3}
    end)
  end

  test "managed native parameters work while raw calls remain disabled" do
    Harness.with_client("native_managed", [native_mode: :managed], fn %{
                                                                        client: client,
                                                                        root: root
                                                                      } ->
      assert {:ok, %{"sessionId" => thread}} =
               Native.new_session(client, root, native_params: %{"ephemeral" => true})

      assert is_binary(thread)
      assert {:error, :native_api_disabled} = Native.subscribe(client)

      assert {:error, %{"message" => "native_api_disabled"}} =
               Native.request(client, "thread/loaded/list")

      %{managed_parameters_verified: true}
    end)
  end
end
