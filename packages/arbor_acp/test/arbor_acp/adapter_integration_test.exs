defmodule Arbor.ACP.AdapterIntegrationTest do
  @moduledoc """
  Integration tests for the full adapter pipeline:
  AdapterTransport → AdapterBridge → Adapter → Port subprocess → back

  Uses `cat` as a real subprocess to verify bidirectional message flow
  through the entire stack.
  """
  use ExUnit.Case, async: true

  alias Arbor.ACP.AdapterBridge
  alias Arbor.ACP.AdapterTransport

  # Full-featured mock adapter using `cat` for round-trip testing.
  # Tracks request IDs so inbound echoes produce proper JSON-RPC responses.
  defmodule IntegrationAdapter do
    @behaviour Arbor.ACP.Adapter

    defstruct [
      :pending_new_id,
      :pending_prompt_id,
      session_id: "test-session"
    ]

    @impl true
    def init(_opts), do: {:ok, %__MODULE__{}}

    @impl true
    def command(_opts), do: {"cat", []}

    @impl true
    def capabilities, do: %{"streaming" => true, "test" => true}

    @impl true
    def translate_outbound(%{"method" => "initialize"}, state) do
      {:ok, :skip, state}
    end

    def translate_outbound(%{"method" => "session/new", "id" => id}, state) do
      state = %{state | pending_new_id: id}
      data = Jason.encode!(%{"_echo" => "new_session", "_id" => id}) <> "\n"
      {:ok, data, state}
    end

    def translate_outbound(
          %{"method" => "session/prompt", "id" => id, "params" => params},
          state
        ) do
      text = extract_text(params["prompt"])
      state = %{state | pending_prompt_id: id}
      data = Jason.encode!(%{"_echo" => "prompt", "_text" => text, "_id" => id}) <> "\n"
      {:ok, data, state}
    end

    def translate_outbound(_msg, state), do: {:ok, :skip, state}

    @impl true
    def translate_inbound(line, state) do
      case Jason.decode(String.trim(line)) do
        {:ok, %{"_echo" => "new_session"}} ->
          response = %{
            "jsonrpc" => "2.0",
            "id" => state.pending_new_id,
            "result" => %{"sessionId" => state.session_id}
          }

          {:messages, [response], %{state | pending_new_id: nil}}

        {:ok, %{"_echo" => "prompt", "_text" => text}} ->
          notification = %{
            "jsonrpc" => "2.0",
            "method" => "session/update",
            "params" => %{
              "sessionId" => state.session_id,
              "update" => %{
                "sessionUpdate" => "agent_message_chunk",
                "content" => %{"type" => "text", "text" => text}
              }
            }
          }

          response = %{
            "jsonrpc" => "2.0",
            "id" => state.pending_prompt_id,
            "result" => %{
              "stopReason" => "end_turn",
              "text" => text,
              "sessionId" => state.session_id
            }
          }

          {:messages, [notification, response], %{state | pending_prompt_id: nil}}

        _ ->
          {:skip, state}
      end
    end

    defp extract_text(nil), do: ""

    defp extract_text(blocks) when is_list(blocks) do
      blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("\n", &(&1["text"] || ""))
    end

    defp extract_text(text) when is_binary(text), do: text
  end

  # Adapter that uses post_connect to perform a handshake with the subprocess.
  # Verifies the skip_and_write return path.
  defmodule HandshakeAdapter do
    @behaviour Arbor.ACP.Adapter

    defstruct phase: :initializing, handshake_done: false

    @impl true
    def init(_opts), do: {:ok, %__MODULE__{}}

    @impl true
    def command(_opts), do: {"cat", []}

    @impl true
    def capabilities, do: %{"handshake" => true}

    @impl true
    def post_connect(state) do
      request =
        Jason.encode!(%{
          "id" => 0,
          "method" => "initialize",
          "params" => %{"clientInfo" => %{"name" => "test"}}
        }) <> "\n"

      {:ok, request, state}
    end

    @impl true
    def translate_outbound(%{"method" => "initialize"}, state) do
      {:ok, :skip, state}
    end

    def translate_outbound(_msg, state), do: {:ok, :skip, state}

    @impl true
    def translate_inbound(line, state) do
      case Jason.decode(String.trim(line)) do
        {:ok, %{"id" => 0, "method" => "initialize"}} ->
          # cat echoed our initialize request — complete the handshake
          state = %{state | phase: :ready, handshake_done: true}
          initialized = Jason.encode!(%{"method" => "initialized"}) <> "\n"
          {:skip_and_write, initialized, state}

        {:ok, %{"method" => "initialized"}} ->
          # cat echoed the initialized notification — ignore
          {:skip, state}

        _ ->
          {:skip, state}
      end
    end
  end

  # Adapter that uses messages_and_write return to send data back while producing messages.
  defmodule WriteBackAdapter do
    @behaviour Arbor.ACP.Adapter

    defstruct ack_count: 0

    @impl true
    def init(_opts), do: {:ok, %__MODULE__{}}

    @impl true
    def command(_opts), do: {"cat", []}

    @impl true
    def translate_outbound(%{"method" => "initialize"}, state), do: {:ok, :skip, state}

    def translate_outbound(%{"method" => "session/prompt", "params" => params}, state) do
      text = get_in(params, ["prompt", Access.at(0), "text"]) || ""
      data = Jason.encode!(%{"_trigger" => "ack", "_text" => text}) <> "\n"
      {:ok, data, state}
    end

    def translate_outbound(_msg, state), do: {:ok, :skip, state}

    @impl true
    def translate_inbound(line, state) do
      case Jason.decode(String.trim(line)) do
        {:ok, %{"_trigger" => "ack", "_text" => text}} ->
          state = %{state | ack_count: state.ack_count + 1}

          notification = %{
            "jsonrpc" => "2.0",
            "method" => "session/update",
            "params" => %{
              "update" => %{
                "sessionUpdate" => "agent_message_chunk",
                "content" => %{"type" => "text", "text" => text}
              }
            }
          }

          # Write an ack back to the subprocess while also producing a message
          ack = Jason.encode!(%{"_ack" => state.ack_count}) <> "\n"
          {:messages_and_write, [notification], ack, state}

        {:ok, %{"_ack" => _count}} ->
          # Ignore the echo of our ack
          {:skip, state}

        _ ->
          {:skip, state}
      end
    end
  end

  # Helper to send initialize and drain the synthesized init response
  defp send_initialize(transport) do
    {:ok, transport} =
      AdapterTransport.send_message(
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "initialize",
          "id" => 0,
          "params" => %{}
        }),
        transport
      )

    {:ok, init_raw, transport} = AdapterTransport.receive_message(transport)
    {Jason.decode!(init_raw), transport}
  end

  defp bridge_send_initialize(bridge) do
    :ok =
      AdapterBridge.send_message(
        bridge,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "initialize",
          "id" => 0,
          "params" => %{}
        })
      )

    {:ok, init_raw} = AdapterBridge.receive_message(bridge, 5_000)
    Jason.decode!(init_raw)
  end

  describe "AdapterTransport full lifecycle" do
    test "connect + init + session/new + prompt round-trip" do
      {:ok, transport} = AdapterTransport.connect(adapter: IntegrationAdapter, adapter_opts: [])

      # 1. Send initialize and receive synthesized init response
      {init_msg, transport} = send_initialize(transport)
      assert init_msg["result"]["agentInfo"]["name"] == "integrationadapter"
      assert init_msg["result"]["agentCapabilities"]["streaming"] == true

      # 2. Send session/new
      {:ok, transport} =
        AdapterTransport.send_message(
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "method" => "session/new",
            "id" => 1,
            "params" => %{}
          }),
          transport
        )

      {:ok, new_raw, transport} = AdapterTransport.receive_message(transport)
      new_resp = Jason.decode!(new_raw)
      assert new_resp["id"] == 1
      assert new_resp["result"]["sessionId"] == "test-session"

      # 3. Send prompt
      {:ok, transport} =
        AdapterTransport.send_message(
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "method" => "session/prompt",
            "id" => 2,
            "params" => %{
              "sessionId" => "test-session",
              "prompt" => [%{"type" => "text", "text" => "Hello from integration"}]
            }
          }),
          transport
        )

      # 4. Receive notification + response
      {:ok, update_raw, transport} = AdapterTransport.receive_message(transport)
      update = Jason.decode!(update_raw)
      assert update["method"] == "session/update"
      assert update["params"]["update"]["sessionUpdate"] == "agent_message_chunk"

      assert update["params"]["update"]["content"] == %{
               "type" => "text",
               "text" => "Hello from integration"
             }

      {:ok, resp_raw, transport} = AdapterTransport.receive_message(transport)
      resp = Jason.decode!(resp_raw)
      assert resp["id"] == 2
      assert resp["result"]["stopReason"] == "end_turn"
      assert resp["result"]["text"] == "Hello from integration"

      AdapterTransport.close(transport)
    end

    test "multiple sequential prompts maintain correct state" do
      {:ok, transport} = AdapterTransport.connect(adapter: IntegrationAdapter, adapter_opts: [])

      # Send initialize and drain init response
      {_init_msg, transport} = send_initialize(transport)

      # session/new
      {:ok, transport} =
        AdapterTransport.send_message(
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "method" => "session/new",
            "id" => 1,
            "params" => %{}
          }),
          transport
        )

      {:ok, _, transport} = AdapterTransport.receive_message(transport)

      # Prompt 1
      {:ok, transport} =
        AdapterTransport.send_message(
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "method" => "session/prompt",
            "id" => 2,
            "params" => %{
              "sessionId" => "test-session",
              "prompt" => [%{"type" => "text", "text" => "First"}]
            }
          }),
          transport
        )

      {:ok, u1, transport} = AdapterTransport.receive_message(transport)
      {:ok, r1, transport} = AdapterTransport.receive_message(transport)

      assert Jason.decode!(u1)["params"]["update"]["content"] == %{
               "type" => "text",
               "text" => "First"
             }

      assert Jason.decode!(r1)["id"] == 2

      # Prompt 2
      {:ok, transport} =
        AdapterTransport.send_message(
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "method" => "session/prompt",
            "id" => 3,
            "params" => %{
              "sessionId" => "test-session",
              "prompt" => [%{"type" => "text", "text" => "Second"}]
            }
          }),
          transport
        )

      {:ok, u2, transport} = AdapterTransport.receive_message(transport)
      {:ok, r2, _transport} = AdapterTransport.receive_message(transport)

      assert Jason.decode!(u2)["params"]["update"]["content"] == %{
               "type" => "text",
               "text" => "Second"
             }

      assert Jason.decode!(r2)["id"] == 3
      assert Jason.decode!(r2)["result"]["text"] == "Second"

      AdapterTransport.close(transport)
    end

    test "connected? tracks bridge liveness" do
      {:ok, transport} = AdapterTransport.connect(adapter: IntegrationAdapter, adapter_opts: [])
      assert AdapterTransport.connected?(transport)

      AdapterTransport.close(transport)
      refute AdapterTransport.connected?(transport)
    end

    test "close is idempotent" do
      {:ok, transport} = AdapterTransport.connect(adapter: IntegrationAdapter, adapter_opts: [])
      assert :ok = AdapterTransport.close(transport)
      assert :ok = AdapterTransport.close(transport)
    end
  end

  describe "post_connect handshake" do
    test "adapter performs initialize handshake via cat echo" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: HandshakeAdapter, adapter_opts: [])

      # The handshake happened internally via post_connect:
      # 1. post_connect wrote initialize request to cat
      # 2. cat echoed it back
      # 3. translate_inbound processed it, sent "initialized" via skip_and_write
      # 4. cat echoed "initialized" back (ignored by translate_inbound)

      # Send initialize to receive synthesized init response
      init_msg = bridge_send_initialize(bridge)
      assert init_msg["result"]["agentCapabilities"]["handshake"] == true

      # Verify bridge is still functional after handshake
      assert :ok =
               AdapterBridge.send_message(
                 bridge,
                 Jason.encode!(%{
                   "jsonrpc" => "2.0",
                   "method" => "test",
                   "id" => 1,
                   "params" => %{}
                 })
               )

      AdapterBridge.close(bridge)
    end
  end

  describe "messages_and_write return type" do
    test "produces messages and writes data back to port" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: WriteBackAdapter, adapter_opts: [])

      # Send initialize and drain init response
      _init_msg = bridge_send_initialize(bridge)

      # Send a prompt that triggers the write-back flow
      prompt_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/prompt",
        "id" => 1,
        "params" => %{
          "sessionId" => "s1",
          "prompt" => [%{"type" => "text", "text" => "write-back test"}]
        }
      }

      :ok = AdapterBridge.send_message(bridge, Jason.encode!(prompt_msg))

      # Receive the notification produced by messages_and_write
      {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)
      assert msg["method"] == "session/update"

      assert msg["params"]["update"]["content"] == %{
               "type" => "text",
               "text" => "write-back test"
             }

      # The ack was written back to cat, which echoed it.
      # translate_inbound skips the ack echo, so no more messages.

      AdapterBridge.close(bridge)
    end
  end

  describe "error scenarios" do
    test "send to closed bridge returns error" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: IntegrationAdapter, adapter_opts: [])
      AdapterBridge.close(bridge)

      # Bridge process is stopped — GenServer.call will exit
      assert catch_exit(
               AdapterBridge.send_message(
                 bridge,
                 Jason.encode!(%{"method" => "test", "id" => 1})
               )
             )
    end

    test "receive from closed bridge returns error" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: IntegrationAdapter, adapter_opts: [])

      # Send initialize and drain init response
      _init_msg = bridge_send_initialize(bridge)

      AdapterBridge.close(bridge)

      assert catch_exit(AdapterBridge.receive_message(bridge, 1_000))
    end

    test "invalid JSON sent to bridge returns decode error" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: IntegrationAdapter, adapter_opts: [])

      assert {:error, {:decode_error, _}} =
               AdapterBridge.send_message(bridge, "not valid json {{{")

      AdapterBridge.close(bridge)
    end
  end
end
