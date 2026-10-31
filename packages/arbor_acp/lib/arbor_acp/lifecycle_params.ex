defmodule Arbor.ACP.LifecycleParams do
  @moduledoc false

  # Pure normalization and validation for ACP session lifecycle parameters.

  alias Arbor.ACP.Capabilities
  alias Arbor.ACP.Internal.Mcp
  alias Arbor.ACP.Maps

  @spec client_opts(keyword()) :: keyword()
  def client_opts(opts) when is_list(opts) do
    Keyword.take(opts, [:mcp_servers, :additional_directories, :meta])
  end

  @spec validate_cwd(any()) :: :ok | {:error, {:invalid_params, :cwd_must_be_absolute}}
  def validate_cwd(cwd) when is_binary(cwd) do
    if absolute_path?(cwd), do: :ok, else: {:error, {:invalid_params, :cwd_must_be_absolute}}
  end

  def validate_cwd(_cwd), do: {:error, {:invalid_params, :cwd_must_be_absolute}}

  @spec validate(keyword(), map() | nil) :: :ok | {:error, term()}
  def validate(opts, capabilities) do
    additional_directories = Keyword.get(opts, :additional_directories)
    mcp_servers = mcp_servers(opts)

    cond do
      not is_nil(Keyword.get(opts, :meta)) and
          not (is_map(Keyword.get(opts, :meta)) and
                   Arbor.ACP.Internal.Extensions.json?(Keyword.get(opts, :meta))) ->
        {:error, :invalid_meta}

      removed_native_mcp_servers?(mcp_servers) ->
        {:error, {:invalid_params, :native_mcp_removed}}

      invalid_acp_mcp_servers?(mcp_servers) ->
        {:error, {:invalid_params, :mcp_server}}

      invalid_beam_mcp_servers?(mcp_servers, capabilities || %{}) ->
        {:error, {:unsupported_capability, :mcp_beam}}

      not Capabilities.supported?(capabilities || %{}, :additional_directories) ->
        if is_nil(additional_directories) do
          :ok
        else
          {:error, {:unsupported_capability, :additional_directories}}
        end

      is_nil(additional_directories) ->
        :ok

      not valid_additional_directories?(additional_directories) ->
        {:error, {:invalid_params, :additional_directories_must_be_absolute_paths}}

      true ->
        :ok
    end
  end

  @spec normalize(map(), keyword() | map() | nil) :: map()
  def normalize(params, opts) when is_map(params) do
    params
    |> Map.put("mcpServers", mcp_servers(opts))
    |> Maps.put_present("additionalDirectories", validate_additional_directories!(opts))
    |> Maps.put_present("_meta", metadata(opts))
  end

  defp metadata(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.get(opts, :meta), else: nil
  end

  defp metadata(opts), do: Maps.get(opts, "_meta")

  @spec mcp_servers(keyword() | map() | nil) :: list()
  def mcp_servers(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.get(opts, :mcp_servers, []), else: opts
  end

  def mcp_servers(%{} = opts) do
    Maps.get(opts, "mcpServers") || Maps.get(opts, :mcp_servers) || Maps.get(opts, :mcpServers) ||
      []
  end

  def mcp_servers(nil), do: []

  @doc false
  @spec select_acp_servers(term(), map() | nil, MapSet.t() | list() | map() | nil) ::
          {:ok, %{servers: list(), server_ids: [String.t()], omitted: [map()]}}
          | {:error, {:invalid_params, :mcp_server | :duplicate_mcp_server_id}}
  def select_acp_servers(servers, capabilities, configured) when is_list(servers) do
    servers
    |> Enum.reduce_while(new_selection(capabilities, configured), &take_server/2)
    |> finish_selection()
  end

  def select_acp_servers(_servers, _capabilities, _configured) do
    {:error, {:invalid_params, :mcp_server}}
  end

  @spec additional_directories(keyword() | map() | nil) :: any()
  def additional_directories(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.get(opts, :additional_directories), else: nil
  end

  def additional_directories(%{} = opts) do
    Maps.get(opts, "additionalDirectories") || Maps.get(opts, :additional_directories) ||
      Maps.get(opts, :additionalDirectories)
  end

  def additional_directories(nil), do: nil

  @spec valid_additional_directories?(any()) :: boolean()
  def valid_additional_directories?(directories) when is_list(directories) do
    directories != [] and Enum.all?(directories, &absolute_path?/1)
  end

  def valid_additional_directories?(_directories), do: false

  @spec validate_additional_directories!(keyword() | map() | nil | list(String.t())) ::
          list(String.t()) | nil
  def validate_additional_directories!(opts) do
    opts
    |> additional_directories()
    |> do_validate_additional_directories!()
  end

  @spec absolute_path?(any()) :: boolean()
  def absolute_path?(path) when is_binary(path) and path != "",
    do: Path.type(path) == :absolute

  def absolute_path?(_path), do: false

  defp do_validate_additional_directories!(nil), do: nil

  defp do_validate_additional_directories!(directories) when is_list(directories) do
    if valid_additional_directories?(directories) do
      directories
    else
      raise ArgumentError, "additionalDirectories must be a non-empty list of absolute paths"
    end
  end

  defp do_validate_additional_directories!(_directories) do
    raise ArgumentError, "additionalDirectories must be a non-empty list of absolute paths"
  end

  defp invalid_beam_mcp_servers?(servers, capabilities) do
    Enum.any?(servers, &beam_mcp_server?/1) and
      not Capabilities.supported?(capabilities, :mcp_beam)
  end

  defp invalid_acp_mcp_servers?(servers) when is_list(servers) do
    Enum.any?(servers, fn server ->
      Mcp.acp_claim?(server) and Mcp.normalize_server(server) == :invalid
    end)
  end

  defp invalid_acp_mcp_servers?(_servers), do: false

  defp new_selection(capabilities, configured) do
    %{
      advertised?: Capabilities.supported?(capabilities || %{}, :mcp_acp),
      configured: configured_set(configured),
      servers: [],
      server_ids: [],
      omitted: []
    }
  end

  defp take_server(server, acc) do
    if Mcp.acp_claim?(server) do
      case Mcp.normalize_server(server) do
        {:acp, id, wire} -> {:cont, keep_or_omit(acc, id, wire)}
        _invalid -> {:halt, :invalid}
      end
    else
      {:cont, %{acc | servers: [server | acc.servers]}}
    end
  end

  defp keep_or_omit(acc, id, wire) do
    reason =
      cond do
        not acc.advertised? -> :mcp_acp_not_advertised
        not MapSet.member?(acc.configured, id) -> :mcp_provider_not_configured
        true -> nil
      end

    if reason do
      %{acc | omitted: [%{id: id, reason: reason} | acc.omitted]}
    else
      %{acc | servers: [wire | acc.servers], server_ids: [id | acc.server_ids]}
    end
  end

  defp finish_selection(:invalid), do: {:error, {:invalid_params, :mcp_server}}

  defp finish_selection(acc) do
    server_ids = Enum.reverse(acc.server_ids)

    if length(server_ids) == length(Enum.uniq(server_ids)) do
      {:ok,
       %{
         servers: Enum.reverse(acc.servers),
         server_ids: server_ids,
         omitted: Enum.reverse(acc.omitted)
       }}
    else
      {:error, {:invalid_params, :duplicate_mcp_server_id}}
    end
  end

  defp configured_set(%MapSet{} = ids), do: ids
  defp configured_set(ids) when is_list(ids), do: MapSet.new(ids)
  defp configured_set(%{} = providers), do: MapSet.new(Map.keys(providers))
  defp configured_set(_configured), do: MapSet.new()

  defp beam_mcp_server?(%{"type" => type}) when type in ["beam"], do: true
  defp beam_mcp_server?(%{type: type}) when type in [:beam, "beam"], do: true
  defp beam_mcp_server?(_server), do: false

  defp removed_native_mcp_servers?(servers), do: Enum.any?(servers, &native_mcp_server?/1)

  defp native_mcp_server?(%{"type" => type}) when type in ["native"], do: true
  defp native_mcp_server?(%{type: type}) when type in [:native, "native"], do: true
  defp native_mcp_server?(_server), do: false
end
