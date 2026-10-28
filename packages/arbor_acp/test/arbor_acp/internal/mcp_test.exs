defmodule Arbor.ACP.Internal.McpTest do
  use ExUnit.Case, async: true

  alias Arbor.ACP.Internal.Mcp

  test "extracts acp server ids and rejects duplicates or malformed entries" do
    servers = [
      %{"name" => "local", "command" => "/usr/bin/server", "args" => [], "env" => []},
      %{"type" => "acp", "name" => "tools", "serverId" => "tools"},
      %{type: :acp, name: "docs", server_id: "docs", meta: %{"trace" => "1"}}
    ]

    assert {:ok, ["tools", "docs"]} = Mcp.acp_server_ids(servers)

    assert {:error, :duplicate_mcp_server_id} =
             Mcp.acp_server_ids([
               %{"type" => "acp", "name" => "tools", "serverId" => "tools"},
               %{"type" => "acp", "name" => "again", "serverId" => "tools"}
             ])

    assert {:ok, [""]} =
             Mcp.acp_server_ids([%{"type" => "acp", "name" => "", "serverId" => ""}])

    assert {:error, :invalid_params} =
             Mcp.acp_server_ids([%{"type" => "acp", "name" => "tools", "serverId" => <<0xFF>>}])

    assert {:error, :invalid_params} =
             Mcp.acp_server_ids([
               %{"type" => "acp", "name" => "tools", "serverId" => "tools", "_meta" => %{atom: 1}}
             ])

    assert {:error, :invalid_params} = Mcp.acp_server_ids(:nope)
  end

  test "normalizes an acp server and leaves other transports unchanged" do
    assert {:acp, "tools", %{"type" => "acp", "name" => "tools", "serverId" => "tools"}} =
             Mcp.normalize_server(%{type: "acp", name: "tools", serverId: "tools", meta: nil})

    assert :other = Mcp.normalize_server(%{"type" => "http", "name" => "docs"})
    assert :invalid = Mcp.normalize_server("acp")
  end

  test "decodes an inner result, including null, ahead of an inner error" do
    assert {:ok, %{"tools" => []}} = Mcp.decode_response(%{"result" => %{"tools" => []}})
    assert {:ok, nil} = Mcp.decode_response(%{"result" => nil})

    assert {:ok, nil} =
             Mcp.decode_response(%{
               "result" => nil,
               "error" => %{"code" => 1, "message" => "ignored"}
             })

    error = %{"code" => -32_601, "message" => "Method not found", "extra" => true}
    assert {:error, {:mcp_error, ^error}} = Mcp.decode_response(%{"error" => error})

    assert {:error, {:mcp_error, %{"code" => 1, "message" => "", "data" => nil}}} =
             Mcp.decode_response(%{"error" => %{"code" => 1, "message" => "", "data" => nil}})

    assert {:error, :invalid_params} =
             Mcp.decode_response(%{
               "result" => :nope,
               "error" => %{"code" => 1, "message" => "no"}
             })

    assert {:error, :invalid_params} =
             Mcp.decode_response(%{"error" => %{"code" => 2_147_483_648, "message" => "too big"}})

    assert {:error, :invalid_params} = Mcp.decode_response(%{})
    assert Mcp.mcp_error?(%{"code" => -2_147_483_648, "message" => "low"})
    refute Mcp.mcp_error?(%{"code" => 1.0, "message" => "float"})
  end

  test "validates mcp/message params" do
    assert :ok =
             Mcp.validate_message(%{
               "serverId" => "tools",
               "requestId" => "req-1",
               "method" => "tools/list",
               "params" => nil,
               "_meta" => %{}
             })

    assert :ok =
             Mcp.validate_message(%{
               "serverId" => "",
               "requestId" => "",
               "method" => ""
             })

    assert {:error, :invalid_params} =
             Mcp.validate_message(%{
               "serverId" => <<0xFF>>,
               "requestId" => "req-1",
               "method" => "tools/list"
             })

    assert {:error, :invalid_params} =
             Mcp.validate_message(%{
               "serverId" => "tools",
               "requestId" => "req-1",
               "method" => "tools/list",
               "params" => ["not", "an", "object"]
             })
  end

  test "reserves, binds, reuses, and releases server ids" do
    table = Mcp.new()
    assert {:ok, pending} = Mcp.begin_new(table, "open-1", ["tools"])
    assert {:error, :pending} = Mcp.session_id(pending, "tools")
    assert {:error, :mcp_server_id_in_use} = Mcp.begin_new(pending, "open-2", ["tools"])

    assert {:error, :duplicate_mcp_server_id} = Mcp.begin_new(table, "open-1", ["tools", "tools"])
    assert table == Mcp.new()

    {aborted, []} = Mcp.abort(pending, "open-1")
    assert :error = Mcp.session_id(aborted, "tools")

    bound = commit_new(table, "open-1", "session-1", ["tools"])
    assert Mcp.declared?(bound, "session-1", "tools")
    assert {:ok, "session-1"} = Mcp.session_id(bound, "tools")
    assert {:error, :mcp_server_id_in_use} = Mcp.begin_new(bound, "fork-1", ["tools"])

    assert {:ok, reused} = Mcp.begin_existing(bound, "session-1", "load-1", ["tools", "docs"])
    assert {:error, :pending} = Mcp.session_id(reused, "docs")
    assert {:ok, "session-1"} = Mcp.session_id(reused, "tools")

    {kept, []} = Mcp.abort(reused, "load-1")
    assert Mcp.declared?(kept, "session-1", "tools")
    assert :error = Mcp.session_id(kept, "docs")

    {:ok, replacing} = Mcp.begin_existing(kept, "session-1", "load-2", ["docs"])
    {replaced, dropped} = Mcp.commit_existing(replacing, "load-2", "session-1", ["docs"])
    assert dropped == []
    refute Mcp.declared?(replaced, "session-1", "tools")
    assert Mcp.declared?(replaced, "session-1", "docs")
    assert {:ok, freed} = Mcp.begin_new(replaced, "open-3", ["tools"])
    assert {:error, :pending} = Mcp.session_id(freed, "tools")

    {cleared, []} = Mcp.commit_existing(replaced, "load-3", "session-1", [])
    assert :error = Mcp.session_id(cleared, "docs")
  end

  test "holds ids a lifecycle call keeps or releases until it finishes" do
    table = commit_new(Mcp.new(), "open-1", "session-1", ["tools", "docs"])

    assert {:ok, keeping} = Mcp.begin_existing(table, "session-1", "keep", ["tools", "extra"])
    assert {:ok, "session-1"} = Mcp.session_id(keeping, "tools")
    assert {:ok, "session-1"} = Mcp.session_id(keeping, "docs")
    assert {:error, :pending} = Mcp.session_id(keeping, "extra")

    assert {:error, :mcp_server_id_in_use} =
             Mcp.begin_existing(keeping, "session-1", "drop", [])

    assert {:error, :mcp_server_id_in_use} = Mcp.begin_new(keeping, "open-2", ["tools"])
    assert {:error, :mcp_server_id_in_use} = Mcp.begin_new(keeping, "open-2", ["docs"])
    assert {:error, :mcp_server_id_in_use} = Mcp.begin_new(keeping, "open-2", ["extra"])

    {kept, []} = Mcp.commit_existing(keeping, "keep", "session-1", ["tools", "extra"])
    assert {:ok, "session-1"} = Mcp.session_id(kept, "tools")
    assert {:ok, "session-1"} = Mcp.session_id(kept, "extra")
    refute Mcp.declared?(kept, "session-1", "docs")

    {:ok, again} = Mcp.begin_existing(table, "session-1", "keep", ["tools"])
    {released, []} = Mcp.abort(again, "keep")
    assert {:ok, "session-1"} = Mcp.session_id(released, "tools")
    assert {:ok, "session-1"} = Mcp.session_id(released, "docs")
    assert {:error, :mcp_server_id_in_use} = Mcp.begin_new(released, "open-2", ["tools"])
  end

  test "a load that releases ids blocks a concurrent claim until it commits" do
    table = commit_new(Mcp.new(), "open-1", "session-1", ["tools"])

    assert {:ok, dropping} = Mcp.begin_existing(table, "session-1", "drop", [])
    assert {:ok, "session-1"} = Mcp.session_id(dropping, "tools")

    assert {:error, :mcp_server_id_in_use} =
             Mcp.begin_existing(dropping, "session-1", "keep", ["tools"])

    assert {:error, :mcp_server_id_in_use} = Mcp.begin_new(dropping, "open-2", ["tools"])

    {cleared, []} = Mcp.commit_existing(dropping, "drop", "session-1", [])
    assert :error = Mcp.session_id(cleared, "tools")
    assert {:ok, _claimed} = Mcp.begin_new(cleared, "open-2", ["tools"])
  end

  test "commit_existing drops in-flight requests for servers removed from the session" do
    table =
      Mcp.new()
      |> commit_new("open-1", "session-1", ["tools", "docs"])
      |> track!("session-1", "tools", "req-tools", 1)
      |> track!("session-1", "docs", "req-docs", 2)

    {:ok, pending} = Mcp.begin_existing(table, "session-1", "load-1", ["docs"])
    {replaced, dropped} = Mcp.commit_existing(pending, "load-1", "session-1", ["docs"])

    assert [%{request_id: "req-tools", outer_id: 1}] = dropped
    assert Mcp.lookup(replaced, "docs", "req-docs")
    assert Mcp.lookup(replaced, "tools", "req-tools") == nil

    {released, released_requests} = Mcp.release_session(replaced, "session-1")
    assert [%{request_id: "req-docs"}] = released_requests
    assert :error = Mcp.session_id(released, "docs")
    assert {:ok, _reused} = Mcp.begin_new(released, "open-2", ["docs"])
  end

  test "release_session waits for an in-flight load hold" do
    table = commit_new(Mcp.new(), "open-1", "session-1", ["tools"])
    {:ok, held} = Mcp.begin_existing(table, "session-1", "load-1", ["tools"])
    {waiting, []} = Mcp.release_session(held, "session-1")

    assert {:ok, "session-1"} = Mcp.session_id(waiting, "tools")

    assert {:error, :mcp_server_id_in_use} = Mcp.begin_new(waiting, "open-2", ["tools"])

    {released, []} = Mcp.commit_existing(waiting, "load-1", "session-1", ["tools"])
    assert :error = Mcp.session_id(released, "tools")
    assert {:ok, _claimed} = Mcp.begin_new(released, "open-2", ["tools"])

    {:ok, again} = Mcp.begin_existing(table, "session-1", "load-2", ["tools"])
    {waiting, []} = Mcp.release_session(again, "session-1")
    {aborted, []} = Mcp.abort(waiting, "load-2")
    assert :error = Mcp.session_id(aborted, "tools")
    refute Mcp.release_pending?(aborted, "session-1")
    assert {:ok, _after_abort} = Mcp.begin_new(aborted, "open-3", ["tools"])
  end

  test "release_session covers an id reserved before the session owns any" do
    {:ok, held} = Mcp.begin_existing(Mcp.new(), "session-1", "load-1", ["tools"])
    assert {:error, :pending} = Mcp.session_id(held, "tools")

    {waiting, []} = Mcp.release_session(held, "session-1")
    assert Mcp.release_pending?(waiting, "session-1")
    assert {:error, :pending} = Mcp.session_id(waiting, "tools")
    assert {:error, :mcp_server_id_in_use} = Mcp.begin_new(waiting, "open-2", ["tools"])

    {released, []} = Mcp.commit_existing(waiting, "load-1", "session-1", ["tools"])
    assert :error = Mcp.session_id(released, "tools")
    refute Mcp.release_pending?(released, "session-1")
    assert {:ok, _claimed} = Mcp.begin_new(released, "open-2", ["tools"])

    {:ok, again} = Mcp.begin_existing(Mcp.new(), "session-1", "load-2", ["tools"])
    {waiting, []} = Mcp.release_session(again, "session-1")
    {aborted, []} = Mcp.abort(waiting, "load-2")
    refute Mcp.release_pending?(aborted, "session-1")
    assert :error = Mcp.session_id(aborted, "tools")

    {:ok, reopened} = Mcp.begin_existing(aborted, "session-1", "load-3", ["tools"])
    {bound, []} = Mcp.commit_existing(reopened, "load-3", "session-1", ["tools"])
    assert {:ok, "session-1"} = Mcp.session_id(bound, "tools")
  end

  test "a close waits for every in-flight reservation of a session that owns nothing" do
    {:ok, first} = Mcp.begin_existing(Mcp.new(), "session-1", "load-a", ["tools"])
    {:ok, both} = Mcp.begin_existing(first, "session-1", "load-b", ["docs"])
    {waiting, []} = Mcp.release_session(both, "session-1")

    {mid, []} = Mcp.commit_existing(waiting, "load-a", "session-1", ["tools"])
    assert :error = Mcp.session_id(mid, "tools")
    assert {:error, :pending} = Mcp.session_id(mid, "docs")
    assert Mcp.release_pending?(mid, "session-1")

    {done, []} = Mcp.commit_existing(mid, "load-b", "session-1", ["docs"])
    assert :error = Mcp.session_id(done, "docs")
    refute Mcp.release_pending?(done, "session-1")
    assert {:ok, _tools} = Mcp.begin_new(done, "open-2", ["tools"])
    assert {:ok, _docs} = Mcp.begin_new(done, "open-3", ["docs"])
  end

  test "a close waits for an in-flight lifecycle call that reserved nothing" do
    {:ok, reserved} = Mcp.begin_existing(Mcp.new(), "session-1", "load-a", ["tools"])
    {:ok, both} = Mcp.begin_existing(reserved, "session-1", "load-b", [])
    {waiting, []} = Mcp.release_session(both, "session-1")
    assert Mcp.release_pending?(waiting, "session-1")

    {mid, []} = Mcp.commit_existing(waiting, "load-a", "session-1", ["tools"])
    assert :error = Mcp.session_id(mid, "tools")
    assert Mcp.release_pending?(mid, "session-1")

    {done, []} = Mcp.commit_existing(mid, "load-b", "session-1", [])
    refute Mcp.release_pending?(done, "session-1")
    assert :error = Mcp.session_id(done, "tools")
    assert {:ok, _reclaimed} = Mcp.begin_new(done, "open-2", ["tools"])

    {:ok, reserved} = Mcp.begin_existing(Mcp.new(), "session-1", "load-c", ["tools"])
    {:ok, both} = Mcp.begin_existing(reserved, "session-1", "load-d", [])
    {waiting, []} = Mcp.release_session(both, "session-1")
    {mid, []} = Mcp.abort(waiting, "load-c")
    assert Mcp.release_pending?(mid, "session-1")
    {aborted, []} = Mcp.abort(mid, "load-d")
    refute Mcp.release_pending?(aborted, "session-1")
    assert :error = Mcp.session_id(aborted, "tools")
  end

  test "a lifecycle call that starts after a close does not inherit it" do
    {:ok, pending} = Mcp.begin_existing(Mcp.new(), "session-1", "load-a", [])
    {waiting, []} = Mcp.release_session(pending, "session-1")
    assert Mcp.release_pending?(waiting, "session-1")

    {:ok, resume} = Mcp.begin_existing(waiting, "session-1", "resume-b", ["fresh"])
    {bound, []} = Mcp.commit_existing(resume, "resume-b", "session-1", ["fresh"])
    assert {:ok, "session-1"} = Mcp.session_id(bound, "fresh")

    {settled, []} = Mcp.commit_existing(bound, "load-a", "session-1", [])
    assert {:ok, "session-1"} = Mcp.session_id(settled, "fresh")
    refute Mcp.release_pending?(settled, "session-1")
  end

  test "a close during a held load drops in-flight requests immediately" do
    table =
      Mcp.new()
      |> commit_new("open-1", "session-1", ["tools"])
      |> track!("session-1", "tools", "req-tools", 1)

    {:ok, held} = Mcp.begin_existing(table, "session-1", "load-1", ["tools"])
    {waiting, dropped} = Mcp.release_session(held, "session-1")

    assert [%{request_id: "req-tools", outer_id: 1}] = dropped
    assert Mcp.lookup(waiting, "tools", "req-tools") == nil
    assert {:ok, "session-1"} = Mcp.session_id(waiting, "tools")

    assert {:error, :unknown_mcp_server} =
             Mcp.track(waiting, entry("session-1", "tools", "req-next", 2), true)

    {released, []} = Mcp.commit_existing(waiting, "load-1", "session-1", ["tools"])
    assert :error = Mcp.session_id(released, "tools")
    refute Mcp.release_pending?(released, "session-1")
  end

  test "closing a session does not cancel a session/new reservation" do
    {:ok, reserved} = Mcp.begin_new(Mcp.new(), "open-1", ["tools"])
    {released, []} = Mcp.release_session(reserved, "session-1")
    assert {:error, :pending} = Mcp.session_id(released, "tools")
    refute Mcp.release_pending?(released, "session-1")
  end

  test "tracks an in-flight request until it finishes" do
    table = commit_new(Mcp.new(), "open-1", "session-1", ["tools"])
    ref = make_ref()

    assert {:error, :unknown_mcp_server} =
             Mcp.track(table, entry("session-1", "missing", "req-1", 1), true)

    assert {:error, :too_many_pending_requests} =
             Mcp.track(table, entry("session-1", "tools", "req-1", 1), false)

    {:ok, tracked} = Mcp.track(table, entry("session-1", "tools", "req-1", 1, ref), true)

    assert {:error, :duplicate_request_id} =
             Mcp.track(tracked, entry("session-1", "tools", "req-1", 2), true)

    assert {:error, :duplicate_request_id} =
             Mcp.track(tracked, entry("session-1", "tools", "req-2", 1), true)

    assert %{outer_id: 1, ref: ^ref, token: ^ref} = Mcp.lookup(tracked, "tools", "req-1")
    assert %{request_id: "req-1"} = Mcp.lookup_outer(tracked, 1)

    {finished, open} = Mcp.finish(tracked, "tools", "req-1")
    assert finished.request_id == "req-1"
    assert Mcp.lookup(open, "tools", "req-1") == nil
    assert {nil, ^open} = Mcp.finish(open, "tools", "req-1")

    {:ok, again} = Mcp.track(open, entry("session-1", "tools", "req-1", 3), true)
    {by_outer, done} = Mcp.finish_outer(again, 3)
    assert by_outer.outer_id == 3
    assert Mcp.lookup_outer(done, 3) == nil
  end

  defp commit_new(table, token, session_id, ids) do
    {:ok, pending} = Mcp.begin_new(table, token, ids)
    Mcp.commit_new(pending, token, session_id, ids)
  end

  defp track!(table, session_id, server_id, request_id, outer_id) do
    {:ok, tracked} = Mcp.track(table, entry(session_id, server_id, request_id, outer_id), true)
    tracked
  end

  defp entry(session_id, server_id, request_id, outer_id, ref \\ nil) do
    %{
      session_id: session_id,
      server_id: server_id,
      request_id: request_id,
      outer_id: outer_id,
      ref: ref
    }
  end
end
