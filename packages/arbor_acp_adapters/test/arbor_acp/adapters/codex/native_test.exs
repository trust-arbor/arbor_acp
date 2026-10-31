defmodule Arbor.ACP.Adapters.Codex.NativeTest do
  use ExUnit.Case, async: true
  alias Arbor.ACP.Client
  alias Arbor.ACP.Adapters.Codex
  alias Arbor.ACP.Adapters.Codex.Native

  @peer Path.expand("../../../fixtures/acp/codex/native_app_server.py", __DIR__)

  defmodule Handler do
    @behaviour Arbor.ACP.Client.Handler
    def init(opts), do: {:ok, Keyword.fetch!(opts, :parent)}
    def handle_session_update(_, _, state), do: {:ok, state}
    def handle_permission_request(_, _, _, state), do: {:ok, %{"outcome" => "cancelled"}, state}

    def handle_extension_request("_arbor/codex/request", %{"method" => "test/error"}, state),
      do:
        {:error,
         %{"code" => -32056, "message" => "tool failed", "data" => false, "future" => [1]}, state}

    def handle_extension_request(
          "_arbor/codex/request",
          %{"method" => method, "params" => params},
          state
        ) do
      send(state, {:native_server_request, method, params})
      {:ok, %{"contentItems" => [], "success" => true, "future" => nil}, state}
    end
  end

  defp start_native(opts \\ []) do
    {:ok, client} =
      Native.start_link(
        Keyword.merge(
          [
            handler: Handler,
            handler_opts: [parent: self()],
            adapter_opts: [codex_path: @peer, workspace_roots: ["/tmp"]]
          ],
          opts
        )
      )

    on_exit(fn -> if Process.alive?(client), do: Client.stop(client) end)
    client
  end

  test "arbitrary future methods preserve values even with raw metadata decoration" do
    client = start_native(native_events: :raw)

    params = %{
      "array" => [1, false, nil],
      "_meta" => %{"native" => "original"},
      "futureField" => %{"x" => true}
    }

    assert {:ok, ^params} = Native.request(client, "future/new-method", params)
    assert :ok = Native.notify(client, "future/notification", %{"new" => true})

    assert {:error, %{"code" => -32055, "data" => [nil, false], "future" => true}} =
             Native.request(client, "test/fail")

    assert {:error, %{"message" => "native_connection_exclusive"}} =
             Client.new_session(client, "/tmp")

    assert {:error, %{"message" => "native_connection_exclusive"}} = Client.list_sessions(client)
  end

  test "subscriptions expose unknown notifications and complete decoded frames" do
    client = start_native()
    assert :ok = Native.subscribe(client)
    assert {:ok, %{}} = Native.request(client, "test/events")

    assert_receive {:acp_extension_notification, "_arbor/codex/event",
                    %{
                      "event" => %{
                        "method" => "future/event",
                        "params" => %{"data" => [1, nil]},
                        "futureTopLevel" => true
                      }
                    }}

    assert_receive {:acp_extension_notification, "_arbor/codex/event",
                    %{
                      "event" => %{
                        "method" => "future/noParams",
                        "futureTopLevel" => [true]
                      }
                    }}

    assert :ok = Native.unsubscribe(client)
  end

  test "server requests and complete error replies round-trip to their native IDs" do
    client = start_native()

    assert {:ok, %{"reply" => %{"id" => id, "result" => %{"success" => true, "future" => nil}}}} =
             Native.request(client, "test/ask")

    assert is_integer(id)

    assert_receive {:native_server_request, "item/tool/call",
                    %{"arguments" => %{"unknown" => true}}}

    assert {:ok,
            %{"reply" => %{"error" => %{"code" => -32056, "data" => false, "future" => [1]}}}} =
             Native.request(client, "test/ask", %{"method" => "test/error"})

    assert {:ok, %{"reply" => %{"result" => _}}} =
             Native.request(client, "test/ask-no-params", %{"method" => "future/request"})

    assert_receive {:native_server_request, "future/request", %{}}
  end

  test "missing server request handlers fail closed" do
    client = start_native(handler: Arbor.ACP.Client.DefaultHandler)

    assert {:ok, %{"reply" => %{"error" => %{"code" => -32601}}}} =
             Native.request(client, "test/ask")
  end

  test "native timeout removes bridge correlation and later requests still work" do
    client = start_native(pending_request_timeout: 40)
    assert {:error, :request_timeout} = Native.request(client, "test/never")
    bridge = :sys.get_state(client).transport_state.bridge
    assert :sys.get_state(bridge).adapter_state.pending_requests == %{}
    assert {:ok, %{}} = Native.request(client, "future/request")
  end

  test "initialization fields and capabilities pass through and failures stop startup" do
    assert {:error, {:native_initialize_failed, %{"data" => %{"future" => true}}}} =
             Native.start_link(
               adapter_opts: [
                 codex_path: @peer,
                 native_initialize_params: %{"clientInfo" => %{"name" => "reject"}}
               ]
             )

    {:ok, state} =
      Codex.init(
        native_initialize_params: %{
          "capabilities" => %{"experimentalApi" => true, "future" => true}
        }
      )

    {:ok, line, _state} = Codex.post_connect(state)

    assert %{"params" => %{"capabilities" => %{"experimentalApi" => true, "future" => true}}} =
             decode(line)
  end

  test "managed prompts retain ACP streaming with structured-output parameters" do
    client = start_native(native_mode: :shared)

    assert {:ok, %{"sessionId" => session}} =
             Native.new_session(client, "/tmp", native_params: %{"ephemeral" => true})

    schema = %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}}}

    assert {:ok, %{text: "structured", result: %{"stopReason" => "end_turn"}}} =
             Native.prompt_text(client, session, "answer",
               native_params: %{"outputSchema" => schema, "futureField" => true}
             )

    assert {:error, %{"message" => "native_params_override_managed_fields"}} =
             Native.prompt(client, session, "answer", native_params: %{"threadId" => "foreign"})
  end

  test "overrides pass future fields and preserve normal parameters across all session methods" do
    {:ok, state} = Codex.init(workspace_roots: ["/tmp"], allow_unbound_threads: true)

    meta = %{
      "arbor.acp.codex" => %{"params" => %{"futureField" => [nil, true], "model" => "custom"}}
    }

    for method <- ["session/new", "session/load", "session/resume"] do
      msg = %{
        "id" => 1,
        "method" => method,
        "params" => %{"cwd" => "/tmp", "sessionId" => "thread", "_meta" => meta}
      }

      assert {:ok, line, _} = Codex.translate_outbound(msg, state)

      assert %{"params" => %{"cwd" => "/tmp", "model" => "custom", "futureField" => [nil, true]}} =
               decode(line)
    end

    state = %{state | sessions: %{"thread" => %{cwd: "/tmp", mode_id: "agent"}}}

    msg = %{
      "id" => 2,
      "method" => "session/prompt",
      "params" => %{
        "sessionId" => "thread",
        "prompt" => [%{"type" => "text", "text" => "hi"}],
        "_meta" => meta
      }
    }

    assert {:ok, line, _} = Codex.translate_outbound(msg, state)

    assert %{
             "params" => %{
               "threadId" => "thread",
               "model" => "custom",
               "futureField" => [nil, true]
             }
           } = decode(line)
  end

  test "managed fields and malformed vendor metadata fail before native writes" do
    {:ok, state} = Codex.init(workspace_roots: ["/tmp"])

    for params <- [%{atom_key: true}, %{"invalid" => self()}, %{"invalid" => {1, 2}}] do
      assert_raise ArgumentError, fn -> Codex.init(native_initialize_params: params) end

      assert_raise ArgumentError, fn ->
        Native.new_session(self(), "/tmp", native_params: params)
      end
    end

    assert_raise ArgumentError, fn ->
      Native.new_session(self(), "/tmp", meta: %{atom_key: true})
    end

    for field <-
          ~w(cwd threadId input config approvalPolicy approvalsReviewer sandbox sandboxPolicy permissions runtimeWorkspaceRoots selectedCapabilityRoots environments) do
      msg = %{
        "id" => 1,
        "method" => "session/new",
        "params" => %{
          "cwd" => "/tmp",
          "_meta" => %{"arbor.acp.codex" => %{"params" => %{field => "override"}}}
        }
      }

      assert {:error, :native_params_override_managed_fields, ^state} =
               Codex.translate_outbound(msg, state)
    end

    msg = %{
      "id" => 1,
      "method" => "session/new",
      "params" => %{"cwd" => "/tmp", "_meta" => %{"arbor.acp.codex" => false}}
    }

    assert {:error, :invalid_native_params, ^state} = Codex.translate_outbound(msg, state)
  end

  test "explicit opt-in, write failure cleanup and native request capacity" do
    msg = %{
      "id" => 1,
      "method" => "_arbor/codex/request",
      "params" => %{"method" => "future/new", "params" => %{}}
    }

    {:ok, state} = Codex.init([])
    state = %{state | phase: :ready}
    assert {:error, :native_api_disabled, _} = Codex.translate_outbound(msg, state)
    {:ok, state} = Codex.init(native_api: :exclusive, max_native_pending_requests: 1)
    state = %{state | phase: :ready}
    assert {:pending_and_write, _, state} = Codex.translate_outbound(msg, state)

    assert {:error, :too_many_native_requests, _} =
             Codex.translate_outbound(%{msg | "id" => 2}, state)

    assert Codex.outbound_write_failed(msg, :closed, state).pending_requests == %{}
  end

  test "native server request resolution cancels the ACP callback and suppresses late replies" do
    {:ok, state} = Codex.init(native_api: :exclusive)

    {:messages, [request, _event], state} =
      Codex.translate_inbound(Jason.encode!(%{"id" => 4, "method" => "future/request"}), state)

    {:messages, [cancel, _event], state} =
      Codex.translate_inbound(
        Jason.encode!(%{"method" => "serverRequest/resolved", "params" => %{"requestId" => 4}}),
        state
      )

    assert cancel["params"]["requestId"] == request["id"]
    assert state.pending_client_requests == %{}

    assert {:ok, :skip, _} =
             Codex.translate_outbound(%{"id" => request["id"], "result" => %{}}, state)
  end

  test "managed mode waits for initialization but keeps raw access and events disabled" do
    client = start_native(native_mode: :managed)
    assert {:error, :native_api_disabled} = Native.subscribe(client)

    assert {:error, %{"message" => "native_api_disabled"}} =
             Native.request(client, "future/request")

    assert {:ok, %{"sessionId" => _}} =
             Native.new_session(client, "/tmp", native_params: %{"future" => true})
  end

  test "turn completion settles only matching native callbacks in exclusive and shared modes" do
    for mode <- [:exclusive, :shared] do
      {:ok, initial} = Codex.init(native_api: mode)

      {requests, state} =
        Enum.map_reduce(
          [
            %{"threadId" => "thread-a", "turnId" => "turn-a"},
            %{"threadId" => "thread-a", "turnId" => "turn-b"},
            %{"threadId" => "thread-b", "turnId" => "turn-a"},
            %{"threadId" => "thread-a"},
            %{}
          ],
          initial,
          fn params, state ->
            {:messages, [request, _event], state} =
              Codex.translate_inbound(
                Jason.encode!(%{
                  "id" => state.next_id,
                  "method" => "future/request",
                  "params" => params
                }),
                state
              )

            {request, state}
          end
        )

      {:messages, messages, unchanged} =
        Codex.translate_inbound(
          Jason.encode!(%{
            "method" => "turn/completed",
            "params" => %{"threadId" => "thread-a", "turn" => %{}}
          }),
          state
        )

      refute Enum.any?(messages, &(&1["method"] == "$/cancel_request"))
      assert unchanged.pending_client_requests == state.pending_client_requests

      completed = %{
        "method" => "turn/completed",
        "params" => %{
          "threadId" => "thread-a",
          "turn" => %{"id" => "turn-a", "status" => "interrupted"}
        }
      }

      {:messages, messages, settled} = Codex.translate_inbound(Jason.encode!(completed), state)
      cancellations = Enum.filter(messages, &(&1["method"] == "$/cancel_request"))
      assert [%{"params" => %{"requestId" => id}}] = cancellations
      assert id == hd(requests)["id"]
      assert map_size(settled.pending_client_requests) == 4
      assert {:ok, :skip, _} = Codex.translate_outbound(%{"id" => id, "result" => %{}}, settled)

      {:messages, repeated, _} = Codex.translate_inbound(Jason.encode!(completed), settled)
      refute Enum.any?(repeated, &(&1["method"] == "$/cancel_request"))
    end
  end

  test "native connections can be supervised and cleanup their owned runtime" do
    {:ok, supervisor} =
      Supervisor.start_link([{Native, [adapter_opts: [codex_path: @peer]]}],
        strategy: :one_for_one
      )

    [{_, client, _, _}] = Supervisor.which_children(supervisor)
    monitor = Process.monitor(client)
    assert {:ok, %{}} = Native.request(client, "future/request")
    assert :ok = Supervisor.stop(supervisor)
    assert_receive {:DOWN, ^monitor, :process, ^client, _}
  end

  defp decode(line), do: line |> IO.iodata_to_binary() |> Jason.decode!()
end
