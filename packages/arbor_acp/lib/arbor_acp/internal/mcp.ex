defmodule Arbor.ACP.Internal.Mcp do
  @moduledoc false

  # Ownership for UNSTABLE MCP-over-ACP.
  #
  # A server id is pending for one in-flight session call or bound to one live
  # session. A lifecycle call that reuses a session also holds every id that
  # session owns until the call commits or aborts, so a concurrent call cannot
  # release or claim those ids. A new id reserved for that session is tagged
  # with the session even before the session owns anything. A load or resume
  # is tracked for its session even when it reserves no id. A resume that
  # omits its server list is tracked the same way and does not reserve or
  # replace ids.
  #
  # Closing a session bumps that session's epoch and drops its in-flight MCP
  # requests immediately. Calls that already started record the epoch from
  # before the bump and may restore or register the session only when it is
  # still current; their ids stay reserved until each of them finishes. A
  # call that starts after the close records the new epoch, so the previous
  # close does not fail it. A session/new reservation has no session yet and
  # does not keep the close. A hold that is not a close leaves in-flight MCP
  # requests running. An inner request id is unique per server while that
  # request is in flight, and its ref is the notify token. Both agent and
  # client keep this table beside their existing pending request maps; this
  # module does not send messages or start timers.

  alias Arbor.ACP.Internal.Extensions

  @int32_min -2_147_483_648
  @int32_max 2_147_483_647

  defstruct sessions: %{},
            servers: %{},
            requests: %{},
            by_outer: %{},
            epochs: %{},
            bound_epochs: %{},
            lifecycle: %{}

  @type entry :: %{
          required(:session_id) => String.t(),
          required(:server_id) => String.t(),
          required(:request_id) => String.t(),
          required(:outer_id) => integer() | String.t(),
          optional(:ref) => reference(),
          optional(:token) => reference()
        }

  @type server :: %{
          required(:owner) => {:pending, term()} | {:session, String.t()},
          optional(:held_by) => term(),
          optional(:for_session) => String.t()
        }

  @type t :: %__MODULE__{
          sessions: %{optional(String.t()) => MapSet.t(String.t())},
          servers: %{optional(String.t()) => server()},
          requests: %{optional({String.t(), String.t()}) => entry()},
          by_outer: %{optional(term()) => {String.t(), String.t()}},
          epochs: %{optional(String.t()) => non_neg_integer()},
          bound_epochs: %{optional(String.t()) => non_neg_integer()},
          lifecycle: %{optional(String.t()) => %{optional(term()) => non_neg_integer()}}
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec acp_claim?(term()) :: boolean()
  def acp_claim?(server) when is_map(server) do
    case fetch_field(server, ["type", :type]) do
      {:ok, type} -> type in ["acp", :acp]
      :error -> false
    end
  end

  def acp_claim?(_server), do: false

  @spec normalize_server(term()) :: {:acp, String.t(), map()} | :other | :invalid
  def normalize_server(server) when is_map(server) do
    if acp_claim?(server), do: normalize_acp(server), else: :other
  end

  def normalize_server(_server), do: :invalid

  @spec acp_server_ids(term()) ::
          {:ok, [String.t()]} | {:error, :invalid_params | :duplicate_mcp_server_id}
  def acp_server_ids(servers) when is_list(servers) do
    Enum.reduce_while(servers, [], fn server, ids ->
      cond do
        acp_claim?(server) ->
          case normalize_server(server) do
            {:acp, id, _wire} ->
              if id in ids, do: {:halt, :duplicate}, else: {:cont, [id | ids]}

            :invalid ->
              {:halt, :invalid}
          end

        is_map(server) ->
          {:cont, ids}

        true ->
          {:halt, :invalid}
      end
    end)
    |> finish_ids()
  end

  def acp_server_ids(_servers), do: {:error, :invalid_params}

  @spec validate_message(term()) :: :ok | {:error, :invalid_params}
  def validate_message(params) do
    if message?(params), do: :ok, else: {:error, :invalid_params}
  end

  @spec decode_response(term()) :: {:ok, term()} | {:error, {:mcp_error, map()} | :invalid_params}
  def decode_response(%{"result" => result}) do
    if Extensions.json?(result), do: {:ok, result}, else: {:error, :invalid_params}
  end

  def decode_response(%{"error" => error}) do
    if mcp_error?(error), do: {:error, {:mcp_error, error}}, else: {:error, :invalid_params}
  end

  def decode_response(_payload), do: {:error, :invalid_params}

  @spec mcp_error?(term()) :: boolean()
  def mcp_error?(%{"code" => code, "message" => message} = error) do
    is_integer(code) and code >= @int32_min and code <= @int32_max and is_binary(message) and
      String.valid?(message) and Extensions.json?(error)
  end

  def mcp_error?(_error), do: false

  @spec begin_new(t(), term(), [String.t()]) ::
          {:ok, t()} | {:error, :duplicate_mcp_server_id | :mcp_server_id_in_use}
  def begin_new(%__MODULE__{} = table, token, ids) when is_list(ids) do
    with :ok <- unique_ids(ids),
         :ok <- available?(table, ids) do
      {:ok, reserve(table, token, ids)}
    end
  end

  @spec begin_existing(t(), String.t(), term(), [String.t()]) ::
          {:ok, t()} | {:error, :duplicate_mcp_server_id | :mcp_server_id_in_use}
  def begin_existing(%__MODULE__{} = table, session_id, token, ids) when is_list(ids) do
    with :ok <- unique_ids(ids),
         :ok <- reusable?(table, session_id, ids),
         :ok <- hold_free?(table, session_id, ids) do
      {:ok, table |> hold(session_id, token, ids) |> track_lifecycle(session_id, token)}
    end
  end

  # Tracks a load or resume that does not send `mcpServers`. The call records
  # the session epoch and does not reserve or replace ids.
  @spec begin_unchanged(t(), String.t(), term()) :: {:ok, t()}
  def begin_unchanged(%__MODULE__{} = table, session_id, token) when is_binary(session_id) do
    {:ok, track_lifecycle(table, session_id, token)}
  end

  @spec abort(t(), term()) :: {t(), [entry()]}
  def abort(%__MODULE__{} = table, token) do
    sessions = Enum.uniq(sessions_held(table, token) ++ lifecycle_sessions(table, token))
    table = table |> clear_pending(token) |> finish_lifecycle_token(token)

    Enum.reduce(sessions, {table, []}, fn session_id, {table, acc} ->
      {table, dropped} = settle_closed(table, session_id)
      {table, acc ++ dropped}
    end)
  end

  @spec commit_new(t(), term(), String.t(), [String.t()]) :: t()
  def commit_new(%__MODULE__{} = table, token, session_id, ids) when is_list(ids) do
    table = clear_pending(table, token)
    table = bind_ids(table, session_id, ids)
    owned = Enum.filter(ids, &owned_by?(table, session_id, &1))
    table |> put_session(session_id, owned, :union) |> accept_epoch(session_id)
  end

  @spec commit_existing(t(), term(), String.t(), [String.t()]) :: {t(), [entry()]}
  def commit_existing(%__MODULE__{} = table, token, session_id, ids) when is_list(ids) do
    stale? = token_stale?(table, session_id, token)
    table = table |> clear_pending(token) |> finish_lifecycle(session_id, token)

    if stale? do
      settle_closed(table, session_id)
    else
      removed = MapSet.difference(servers_for(table, session_id), MapSet.new(ids))
      {table, dropped} = drop_servers(table, removed)
      table = bind_ids(table, session_id, ids)
      owned = Enum.filter(ids, &owned_by?(table, session_id, &1))
      {table |> put_session(session_id, owned, :replace) |> accept_epoch(session_id), dropped}
    end
  end

  # The call omitted `mcpServers`. Accept the current bindings when this call's
  # epoch is still current; otherwise release the close without restoring them.
  @spec finish_unchanged(t(), term(), String.t()) :: {t(), [entry()]}
  def finish_unchanged(%__MODULE__{} = table, token, session_id) do
    stale? = token_stale?(table, session_id, token)
    table = finish_lifecycle(table, session_id, token)

    if stale? do
      settle_closed(table, session_id)
    else
      {accept_epoch(table, session_id), []}
    end
  end

  @spec release_pending?(t(), String.t()) :: boolean()
  def release_pending?(%__MODULE__{} = table, session_id) do
    doomed?(table, session_id) and stale_open?(table, session_id)
  end

  # True when this call started before the session's latest close.
  @spec token_closed?(t(), String.t(), term()) :: boolean()
  def token_closed?(%__MODULE__{} = table, session_id, token) do
    token_stale?(table, session_id, token)
  end

  @spec release_session(t(), String.t()) :: {t(), [entry()]}
  def release_session(%__MODULE__{} = table, session_id) do
    table = bump_epoch(table, session_id)
    {table, dropped} = drop_requests(table, servers_for(table, session_id))

    if release_blocked?(table, session_id) do
      {table, dropped}
    else
      {table, more} = drop_session(table, session_id)
      {table, dropped ++ more}
    end
  end

  @spec session_id(t(), String.t()) :: {:ok, String.t()} | {:error, :pending} | :error
  def session_id(%__MODULE__{} = table, server_id) do
    case Map.get(table.servers, server_id) do
      %{owner: {:session, session_id}} -> {:ok, session_id}
      %{owner: {:pending, _token}} -> {:error, :pending}
      _missing -> :error
    end
  end

  @spec declared?(t(), String.t(), String.t()) :: boolean()
  def declared?(%__MODULE__{} = table, session_id, server_id) do
    owned_by?(table, session_id, server_id)
  end

  @spec track(t(), entry(), boolean()) ::
          {:ok, t()}
          | {:error, :unknown_mcp_server | :duplicate_request_id | :too_many_pending_requests}
  def track(
        %__MODULE__{} = table,
        %{
          session_id: session_id,
          server_id: server_id,
          request_id: request_id,
          outer_id: outer_id
        } =
          entry,
        room?
      )
      when is_boolean(room?) do
    key = {server_id, request_id}

    cond do
      not owned_by?(table, session_id, server_id) ->
        {:error, :unknown_mcp_server}

      doomed?(table, session_id) ->
        {:error, :unknown_mcp_server}

      Map.has_key?(table.requests, key) or Map.has_key?(table.by_outer, outer_id) ->
        {:error, :duplicate_request_id}

      not room? ->
        {:error, :too_many_pending_requests}

      true ->
        stored = store_entry(entry)

        {:ok,
         %{
           table
           | requests: Map.put(table.requests, key, stored),
             by_outer: Map.put(table.by_outer, outer_id, key)
         }}
    end
  end

  @spec lookup(t(), String.t(), String.t()) :: entry() | nil
  def lookup(%__MODULE__{} = table, server_id, request_id) do
    Map.get(table.requests, {server_id, request_id})
  end

  @spec lookup_outer(t(), term()) :: entry() | nil
  def lookup_outer(%__MODULE__{} = table, outer_id) do
    case Map.get(table.by_outer, outer_id) do
      nil -> nil
      key -> Map.get(table.requests, key)
    end
  end

  @spec finish(t(), String.t(), String.t()) :: {entry() | nil, t()}
  def finish(%__MODULE__{} = table, server_id, request_id) do
    case Map.pop(table.requests, {server_id, request_id}) do
      {nil, _requests} ->
        {nil, table}

      {entry, requests} ->
        {entry,
         %{table | requests: requests, by_outer: Map.delete(table.by_outer, entry.outer_id)}}
    end
  end

  @spec finish_outer(t(), term()) :: {entry() | nil, t()}
  def finish_outer(%__MODULE__{} = table, outer_id) do
    case Map.pop(table.by_outer, outer_id) do
      {nil, _by_outer} ->
        {nil, table}

      {key, by_outer} ->
        {entry, requests} = Map.pop(table.requests, key)
        {entry, %{table | requests: requests, by_outer: by_outer}}
    end
  end

  defp finish_ids(:duplicate), do: {:error, :duplicate_mcp_server_id}
  defp finish_ids(:invalid), do: {:error, :invalid_params}
  defp finish_ids(ids), do: {:ok, Enum.reverse(ids)}

  defp normalize_acp(server) do
    with {:ok, name} <- fetch_field(server, ["name", :name]),
         {:ok, id} <- fetch_field(server, ["serverId", :server_id, :serverId]),
         true <- text?(name) and text?(id),
         :ok <- meta_ok?(server) do
      wire =
        %{"type" => "acp", "name" => name, "serverId" => id}
        |> put_meta(meta_value(server))

      {:acp, id, wire}
    else
      _invalid -> :invalid
    end
  end

  defp message?(
         %{"serverId" => server_id, "requestId" => request_id, "method" => method} = params
       ) do
    text?(server_id) and text?(request_id) and text?(method) and
      optional_json_object?(params, "params") and optional_json_object?(params, "_meta")
  end

  defp message?(_params), do: false

  defp optional_json_object?(map, key) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, nil} -> true
      {:ok, value} -> json_object?(value)
    end
  end

  defp json_object?(value) when is_map(value), do: Extensions.json?(value)
  defp json_object?(_value), do: false

  defp meta_ok?(server) do
    case fetch_field(server, ["_meta", :meta, :_meta]) do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, meta} -> if json_object?(meta), do: :ok, else: :error
    end
  end

  defp meta_value(server) do
    case fetch_field(server, ["_meta", :meta, :_meta]) do
      {:ok, meta} when is_map(meta) -> if json_object?(meta), do: meta, else: nil
      _missing -> nil
    end
  end

  defp put_meta(wire, nil), do: wire
  defp put_meta(wire, meta), do: Map.put(wire, "_meta", meta)

  # SDK 1.9 types these as strings with no minLength, so "" is a real id.
  defp text?(value), do: is_binary(value) and String.valid?(value)

  defp fetch_field(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> {:ok, value}
        :error -> nil
      end
    end) || :error
  end

  defp unique_ids(ids) do
    if length(ids) == length(Enum.uniq(ids)), do: :ok, else: {:error, :duplicate_mcp_server_id}
  end

  defp available?(table, ids) do
    if Enum.all?(ids, &(not Map.has_key?(table.servers, &1))),
      do: :ok,
      else: {:error, :mcp_server_id_in_use}
  end

  defp reusable?(table, session_id, ids) do
    free? =
      Enum.all?(ids, fn id ->
        case Map.get(table.servers, id) do
          nil -> true
          %{owner: {:session, ^session_id}} -> true
          _taken -> false
        end
      end)

    if free?, do: :ok, else: {:error, :mcp_server_id_in_use}
  end

  # The requested ids and every id this session currently owns must be free of
  # another in-flight lifecycle call. Pending ids and held ids are not.
  defp hold_free?(table, session_id, ids) do
    targets = MapSet.union(MapSet.new(ids), servers_for(table, session_id))

    free? =
      Enum.all?(targets, fn id ->
        case Map.get(table.servers, id) do
          %{held_by: _token} -> false
          %{owner: {:pending, _token}} -> false
          _free -> true
        end
      end)

    if free?, do: :ok, else: {:error, :mcp_server_id_in_use}
  end

  defp hold(table, session_id, token, ids) do
    targets = MapSet.union(MapSet.new(ids), servers_for(table, session_id))

    servers =
      Enum.reduce(targets, table.servers, fn id, servers ->
        case Map.get(servers, id) do
          %{owner: {:session, ^session_id}} = server ->
            Map.put(servers, id, Map.put(server, :held_by, token))

          nil ->
            Map.put(servers, id, %{owner: {:pending, token}, for_session: session_id})

          _taken ->
            servers
        end
      end)

    %{table | servers: servers}
  end

  defp reserve(table, _token, []), do: table

  defp reserve(table, token, ids) do
    servers =
      Enum.reduce(ids, table.servers, fn id, servers ->
        Map.put(servers, id, %{owner: {:pending, token}})
      end)

    %{table | servers: servers}
  end

  # Owned ids held by a lifecycle call, ids that call reserved for this
  # session before they were bound, and any load or resume still in flight
  # for the session, including one that reserved nothing or omitted its
  # server list. A `session/new` reservation has no session yet, so it does
  # not block a close. Blocking keeps the ids reserved. The close has already
  # dropped in-flight MCP requests.
  defp release_blocked?(table, session_id) do
    lifecycle_open?(table, session_id) or
      Enum.any?(table.servers, fn
        {_id, %{held_by: _token, owner: {:session, ^session_id}}} -> true
        {_id, %{owner: {:pending, _token}, for_session: ^session_id}} -> true
        _other -> false
      end)
  end

  defp track_lifecycle(table, session_id, token) do
    tokens = Map.get(table.lifecycle, session_id, %{})
    tokens = Map.put(tokens, token, epoch(table, session_id))
    %{table | lifecycle: Map.put(table.lifecycle, session_id, tokens)}
  end

  defp finish_lifecycle(table, session_id, token) do
    case Map.get(table.lifecycle, session_id) do
      nil ->
        table

      tokens ->
        tokens = Map.delete(tokens, token)

        lifecycle =
          if map_size(tokens) == 0,
            do: Map.delete(table.lifecycle, session_id),
            else: Map.put(table.lifecycle, session_id, tokens)

        %{table | lifecycle: lifecycle}
    end
  end

  defp finish_lifecycle_token(table, token) do
    Enum.reduce(lifecycle_sessions(table, token), table, fn session_id, table ->
      finish_lifecycle(table, session_id, token)
    end)
  end

  defp lifecycle_sessions(table, token) do
    Enum.flat_map(table.lifecycle, fn {session_id, tokens} ->
      if Map.has_key?(tokens, token), do: [session_id], else: []
    end)
  end

  defp lifecycle_open?(table, session_id), do: Map.has_key?(table.lifecycle, session_id)

  defp epoch(table, session_id), do: Map.get(table.epochs, session_id, 0)

  defp bound_epoch(table, session_id), do: Map.get(table.bound_epochs, session_id, 0)

  defp doomed?(table, session_id), do: epoch(table, session_id) > bound_epoch(table, session_id)

  defp bump_epoch(table, session_id) do
    %{table | epochs: Map.put(table.epochs, session_id, epoch(table, session_id) + 1)}
  end

  defp accept_epoch(table, session_id) do
    %{table | bound_epochs: Map.put(table.bound_epochs, session_id, epoch(table, session_id))}
  end

  defp token_stale?(table, session_id, token) do
    case Map.get(table.lifecycle, session_id) do
      %{^token => started} -> started < epoch(table, session_id)
      _missing -> false
    end
  end

  defp stale_open?(table, session_id) do
    current = epoch(table, session_id)

    case Map.get(table.lifecycle, session_id) do
      nil -> false
      tokens -> Enum.any?(tokens, fn {_token, started} -> started < current end)
    end
  end

  # Drop a closed session once every call that started before the close has
  # finished, unless a later call has already accepted this epoch.
  defp settle_closed(table, session_id) do
    if doomed?(table, session_id) and not lifecycle_open?(table, session_id) do
      drop_session(table, session_id)
    else
      {table, []}
    end
  end

  defp sessions_held(table, token) do
    table.servers
    |> Enum.flat_map(fn
      {_id, %{held_by: ^token, owner: {:session, session_id}}} -> [session_id]
      {_id, %{owner: {:pending, ^token}, for_session: session_id}} -> [session_id]
      _other -> []
    end)
    |> Enum.uniq()
  end

  defp drop_session(table, session_id) do
    {table, dropped} = drop_servers(table, servers_for(table, session_id))
    # No lifecycle token still observes this session here: callers retain a
    # closed session until all reservations have settled. Forget the epoch
    # together with its bindings so closed ids do not become a history log.
    {%{
       table
       | sessions: Map.delete(table.sessions, session_id),
         epochs: Map.delete(table.epochs, session_id),
         bound_epochs: Map.delete(table.bound_epochs, session_id)
     }, dropped}
  end

  defp clear_pending(table, token) do
    servers =
      Enum.reduce(table.servers, %{}, fn {id, server}, acc ->
        cond do
          server.owner == {:pending, token} ->
            acc

          Map.get(server, :held_by) == token ->
            Map.put(acc, id, Map.delete(server, :held_by))

          true ->
            Map.put(acc, id, server)
        end
      end)

    %{table | servers: servers}
  end

  defp bind_ids(table, session_id, ids) do
    servers =
      Enum.reduce(ids, table.servers, fn id, servers ->
        case Map.get(servers, id) do
          nil -> Map.put(servers, id, %{owner: {:session, session_id}})
          %{owner: {:session, ^session_id}} -> servers
          _taken -> servers
        end
      end)

    %{table | servers: servers}
  end

  defp put_session(table, session_id, [], :replace) do
    %{table | sessions: Map.delete(table.sessions, session_id)}
  end

  defp put_session(table, _session_id, [], :union), do: table

  defp put_session(table, session_id, ids, :replace) do
    %{table | sessions: Map.put(table.sessions, session_id, MapSet.new(ids))}
  end

  defp put_session(table, session_id, ids, :union) do
    merged = MapSet.union(servers_for(table, session_id), MapSet.new(ids))
    %{table | sessions: Map.put(table.sessions, session_id, merged)}
  end

  defp servers_for(table, session_id), do: Map.get(table.sessions, session_id, MapSet.new())

  defp owned_by?(table, session_id, server_id) do
    match?(%{owner: {:session, ^session_id}}, Map.get(table.servers, server_id))
  end

  defp drop_servers(table, server_ids) do
    server_ids = MapSet.new(server_ids)
    {table, dropped} = drop_requests(table, server_ids)
    servers = Enum.reduce(server_ids, table.servers, &Map.delete(&2, &1))
    {%{table | servers: servers}, dropped}
  end

  defp drop_requests(table, server_ids) do
    {dropped_pairs, kept_pairs} =
      Enum.split_with(table.requests, fn {{server_id, _request_id}, _entry} ->
        MapSet.member?(server_ids, server_id)
      end)

    dropped = Enum.map(dropped_pairs, &elem(&1, 1))

    by_outer =
      Enum.reduce(dropped, table.by_outer, fn entry, acc ->
        Map.delete(acc, entry.outer_id)
      end)

    {%{table | requests: Map.new(kept_pairs), by_outer: by_outer}, dropped}
  end

  defp store_entry(entry) do
    stored = %{
      session_id: entry.session_id,
      server_id: entry.server_id,
      request_id: entry.request_id,
      outer_id: entry.outer_id
    }

    case Map.get(entry, :ref) do
      ref when is_reference(ref) -> Map.merge(stored, %{ref: ref, token: ref})
      _other -> stored
    end
  end
end
