defmodule Arbor.ACP.CompatTest do
  use ExUnit.Case, async: true

  alias Arbor.ACP.Compat, as: ACPCompat

  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)

  @manifest %{
    "schemaVersion" => 1,
    "catalog" => %{
      "source" => "https://example.test/agents.md",
      "agents" => ["Agent One", "Agent Two"]
    },
    "registry" => %{
      "source" => "https://example.test/registry.json",
      "agents" => [
        %{"id" => "agent-one", "version" => "1.0.0"},
        %{"id" => "agent-two", "version" => "2.0.0"}
      ]
    },
    "adapterUpstreams" => [
      %{
        "id" => "reference-adapter",
        "adapter" => "Arbor.ACP.Adapters.Reference",
        "repository" => "https://github.com/example/reference-adapter",
        "branch" => "main",
        "commit" => @sha_a
      }
    ],
    "interopAgents" => [
      %{
        "id" => "agent-one",
        "catalogName" => "Agent One",
        "tier" => "initialize",
        "command" => ["agent-one", "--acp"]
      }
    ]
  }

  describe "validate_manifest/1" do
    test "accepts a complete reviewed manifest" do
      assert :ok = ACPCompat.validate_manifest(@manifest)
    end

    test "rejects duplicate executable entries" do
      duplicate = hd(@manifest["interopAgents"])
      manifest = put_in(@manifest, ["interopAgents"], [duplicate, duplicate])

      assert {:error, :duplicate_interop_agents} = ACPCompat.validate_manifest(manifest)
    end

    test "requires HTTPS drift sources" do
      manifest = put_in(@manifest, ["catalog", "source"], "http://example.test/agents.md")

      assert {:error, {:invalid_source, "catalog"}} = ACPCompat.validate_manifest(manifest)
    end

    test "requires full immutable upstream revisions" do
      manifest = put_in(@manifest, ["adapterUpstreams", Access.at(0), "commit"], "main")

      assert {:error, :invalid_adapter_upstreams} = ACPCompat.validate_manifest(manifest)
    end

    test "rejects mutable npx package commands" do
      manifest =
        put_in(
          @manifest,
          ["interopAgents", Access.at(0), "command"],
          ["npx", "-y", "agent-one"]
        )

      assert {:error, :invalid_interop_agents} = ACPCompat.validate_manifest(manifest)
    end
  end

  describe "parse_catalog/1" do
    test "extracts only the primary link from agent bullets" do
      markdown = """
      # Agents

      The following agents can be used with an ACP Client:

      - [Agent Two](https://example.test/two)
      - [Agent One](https://example.test/one) (via [adapter](https://example.test/adapter))
      """

      assert {:ok, ["Agent One", "Agent Two"]} = ACPCompat.parse_catalog(markdown)
    end

    test "fails closed when the page shape no longer contains agent bullets" do
      assert {:error, :no_catalog_agents_found} = ACPCompat.parse_catalog("# Agents\nNo list")
    end
  end

  describe "registry_snapshot/1" do
    test "keeps stable identity and version fields in id order" do
      registry = %{
        "agents" => [
          %{"id" => "z", "version" => "2.0.0", "description" => "ignored"},
          %{"id" => "a", "version" => "1.0.0", "distribution" => %{}}
        ]
      }

      assert {:ok,
              [
                %{"id" => "a", "version" => "1.0.0"},
                %{"id" => "z", "version" => "2.0.0"}
              ]} = ACPCompat.registry_snapshot(registry)
    end
  end

  describe "compare/2" do
    test "reports catalog, registry, and adapter upstream drift" do
      snapshots = %{
        catalog: ["Agent One", "Agent Three"],
        registry: [
          %{"id" => "agent-one", "version" => "1.1.0"},
          %{"id" => "agent-three", "version" => "3.0.0"}
        ],
        upstreams: %{"reference-adapter" => @sha_b}
      }

      drift = ACPCompat.compare(@manifest, snapshots)

      assert %{
               "kind" => "catalog",
               "added" => ["Agent Three"],
               "removed" => ["Agent Two"]
             } in drift

      assert registry = Enum.find(drift, &(&1["kind"] == "registry"))
      assert registry["added"] == ["agent-three"]
      assert registry["removed"] == ["agent-two"]

      assert registry["versionChanges"] == [
               %{
                 "id" => "agent-one",
                 "expectedVersion" => "1.0.0",
                 "actualVersion" => "1.1.0"
               }
             ]

      assert upstream = Enum.find(drift, &(&1["kind"] == "adapter_upstream"))
      assert upstream["expected"] == @sha_a
      assert upstream["actual"] == @sha_b
      assert upstream["compareUrl"] =~ "/compare/#{@sha_a}...#{@sha_b}"
    end

    test "returns no drift for matching snapshots" do
      snapshots = %{
        catalog: @manifest["catalog"]["agents"],
        registry: @manifest["registry"]["agents"],
        upstreams: %{"reference-adapter" => @sha_a}
      }

      assert ACPCompat.compare(@manifest, snapshots) == []
    end
  end

  describe "check_remote/2" do
    test "fetches all source types through the injected HTTP client" do
      parent = self()

      http_client = fn url, headers, _timeout, _options ->
        send(parent, {:request, url, headers})

        case url do
          "https://example.test/agents.md" ->
            {:ok,
             "- [Agent One](https://example.test/one)\n" <>
               "- [Agent Two](https://example.test/two)\n"}

          "https://example.test/registry.json" ->
            {:ok, Jason.encode!(%{"agents" => @manifest["registry"]["agents"]})}

          "https://api.github.com/repos/example/reference-adapter/commits/main" ->
            {:ok, Jason.encode!(%{"sha" => @sha_a})}
        end
      end

      report = ACPCompat.check_remote(@manifest, http_client: http_client)

      assert report.drift == []
      assert report.errors == []
      assert_receive {:request, "https://example.test/agents.md", _headers}
      assert_receive {:request, "https://example.test/registry.json", _headers}

      assert_receive {:request,
                      "https://api.github.com/repos/example/reference-adapter/commits/main",
                      _headers}
    end

    test "reports source failures without treating empty fetches as authoritative removals" do
      http_client = fn _url, _headers, _timeout, _options -> {:error, :offline} end

      report = ACPCompat.check_remote(@manifest, http_client: http_client)

      assert length(report.errors) == 3
      assert Enum.any?(report.errors, &(&1["source"] == "catalog"))
      assert Enum.any?(report.errors, &(&1["source"] == "registry"))
      assert Enum.any?(report.errors, &(&1["source"] == "adapter_upstream:reference-adapter"))
    end

    test "does not forward the GitHub token on a cross-origin redirect" do
      parent = self()
      secret = "compat-redirect-secret-#{System.unique_integer([:positive])}"

      # Second origin on 127.0.0.2 so a followed 3xx is a different host, not
      # just another port on 127.0.0.1. OTP 28 :httpc still follows by default
      # but strips Authorization on that hop, so asserting "no Bearer token"
      # passes even when the request is replayed. The hop itself must not occur.
      {_target_pid, target_port} =
        start_http_stub(
          fn request ->
            send(parent, {:target_request, request.headers})

            http_response(
              200,
              [{"content-type", "application/json"}],
              Jason.encode!(%{"sha" => @sha_a})
            )
          end,
          {127, 0, 0, 2}
        )

      location = "http://127.0.0.2:#{target_port}/leaked.json"

      {_origin_pid, origin_port} =
        start_http_stub(fn request ->
          send(parent, {:origin_request, request.headers})
          http_response(302, [{"location", location}], "")
        end)

      http_client = fn url, headers, timeout, options ->
        cond do
          String.starts_with?(url, "https://api.github.com/") ->
            replay_http_get(
              "http://127.0.0.1:#{origin_port}/repos/example/reference-adapter/commits/main",
              headers,
              timeout,
              options
            )

          url == @manifest["catalog"]["source"] ->
            {:ok,
             "- [Agent One](https://example.test/one)\n" <>
               "- [Agent Two](https://example.test/two)\n"}

          url == @manifest["registry"]["source"] ->
            {:ok, Jason.encode!(%{"agents" => @manifest["registry"]["agents"]})}
        end
      end

      report =
        ACPCompat.check_remote(@manifest,
          http_client: http_client,
          github_token: secret,
          timeout: 2_000
        )

      assert_receive {:origin_request, origin_headers}
      assert authorization_value(origin_headers) == "Bearer #{secret}"

      refute_received {:target_request, _headers}

      assert Enum.any?(report.errors, fn error ->
               error["source"] == "adapter_upstream:reference-adapter"
             end)
    end
  end

  describe "interop_agent/2" do
    test "returns only explicitly reviewed executable entries" do
      assert {:ok, %{"command" => ["agent-one", "--acp"]}} =
               ACPCompat.interop_agent(@manifest, "agent-one")

      assert {:error, :unknown_agent} = ACPCompat.interop_agent(@manifest, "not-reviewed")
    end
  end

  describe "checked-in manifest" do
    test "tracks the full catalog baseline and all adapter reference repositories" do
      assert {:ok, manifest} = ACPCompat.load_manifest()
      assert length(manifest["catalog"]["agents"]) == 48
      assert length(manifest["registry"]["agents"]) == 43

      repositories = Enum.map(manifest["adapterUpstreams"], & &1["repository"])

      assert "https://github.com/agentclientprotocol/claude-agent-acp" in repositories
      assert "https://github.com/agentclientprotocol/codex-acp" in repositories
      assert "https://github.com/svkozak/pi-acp" in repositories
      assert "https://github.com/zai-org/ZCode" in repositories

      assert Enum.sort(Enum.map(manifest["adapterUpstreams"], & &1["id"])) ==
               ~w(claude-agent-acp codex-acp pi-acp zcode)

      assert Enum.sort(Enum.map(manifest["interopAgents"], & &1["id"])) ==
               ~w(claude-acp codex-acp gemini pi-acp)
    end
  end

  defp replay_http_get(url, headers, timeout, options) do
    _ = Application.ensure_all_started(:inets)

    request = {String.to_charlist(url), charlist_headers(headers)}
    http_options = [timeout: timeout, connect_timeout: timeout] ++ List.wrap(options)

    case :httpc.request(:get, request, http_options, body_format: :binary) do
      {:ok, {{_, status, _}, _response_headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_, status, reason}, _response_headers, _body}} ->
        {:error, {:http_error, status, to_string(reason)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp charlist_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp authorization_value(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if name == "authorization", do: value
    end)
  end

  defp start_http_stub(handler, ip \\ {127, 0, 0, 1}) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: ip,
        backlog: 16
      ])

    {:ok, port} = :inet.port(listen)

    pid =
      spawn_link(fn ->
        http_stub_loop(listen, handler)
      end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :gen_tcp.close(listen)
    end)

    {pid, port}
  end

  defp http_stub_loop(listen, handler) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, socket} ->
        _ = serve_http_stub(socket, handler)
        :gen_tcp.close(socket)
        http_stub_loop(listen, handler)

      {:error, :timeout} ->
        http_stub_loop(listen, handler)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve_http_stub(socket, handler) do
    with {:ok, request} <- recv_http_request(socket) do
      :gen_tcp.send(socket, handler.(request))
    end
  end

  defp recv_http_request(socket), do: recv_http_request(socket, "")

  defp recv_http_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        acc = acc <> data

        case String.split(acc, "\r\n\r\n", parts: 2) do
          [header_block, _body] -> {:ok, parse_http_request(header_block)}
          _ -> recv_http_request(socket, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_http_request(header_block) do
    [request_line | header_lines] = String.split(header_block, "\r\n")
    [method, path | _] = String.split(request_line, " ")

    headers =
      Enum.map(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(String.trim(name)), String.trim(value)}
      end)

    %{method: method, path: path, headers: headers}
  end

  defp http_response(status, headers, body) when is_binary(body) do
    status_line =
      case status do
        200 -> "HTTP/1.1 200 OK"
        302 -> "HTTP/1.1 302 Found"
        _ -> "HTTP/1.1 #{status} X"
      end

    header_lines =
      [
        {"content-length", Integer.to_string(byte_size(body))},
        {"connection", "close"}
        | headers
      ]
      |> Enum.map(fn {name, value} -> "#{name}: #{value}" end)
      |> Enum.join("\r\n")

    "#{status_line}\r\n#{header_lines}\r\n\r\n#{body}"
  end
end
