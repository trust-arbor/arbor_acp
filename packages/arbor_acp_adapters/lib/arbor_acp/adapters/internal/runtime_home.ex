defmodule Arbor.ACP.Adapters.Internal.RuntimeHome do
  @moduledoc false

  # Private per-ACP-session config directories for vendor CLIs. Created 0700
  # under System.tmp_dir/0, keyed by session id (or :connection before one
  # exists), and removed on session close or when the process that requested
  # them exits. A caller :env vendor var or explicit option is the source of
  # truth and is not minted over.

  @dir_prefix "arbor_acp_runtime_home_"
  @owned_key {__MODULE__, :owned_homes}

  @kinds %{
    claude: %{env: "CLAUDE_CONFIG_DIR", option: :claude_config_dir},
    codex: %{env: "CODEX_HOME", option: :codex_home},
    pi: %{env: "PI_CODING_AGENT_DIR", option: :agent_dir}
  }

  @spec trust_workspace_config?(keyword()) :: boolean()
  def trust_workspace_config?(opts) when is_list(opts),
    do: Keyword.get(opts, :trust_workspace_config, false) == true

  def trust_workspace_config?(_opts), do: false

  @spec env_var(atom()) :: String.t()
  def env_var(kind), do: spec!(kind).env

  @spec env_value(keyword(), String.t()) :: String.t() | nil
  def env_value(opts, name) when is_list(opts) and is_binary(name) do
    case env_get(Keyword.get(opts, :env, []), name) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        if Keyword.get(opts, :environment_policy) == :inherit do
          case System.get_env(name) do
            value when is_binary(value) and value != "" -> value
            _ -> nil
          end
        else
          nil
        end
    end
  end

  def env_value(_opts, _name), do: nil

  @spec path(keyword(), atom()) :: String.t() | nil
  def path(opts, kind) when is_list(opts) do
    spec = spec!(kind)

    case configured_path(opts, spec) do
      path when is_binary(path) ->
        path

      nil ->
        if trust_workspace_config?(opts) do
          nil
        else
          cached_or_create(opts, kind)
        end
    end
  end

  def path(_opts, _kind), do: nil

  @spec put(map(), keyword(), atom()) :: map()
  def put(env, opts, kind) when is_map(env) do
    case path(opts, kind) do
      nil -> env
      path -> Map.put(env, env_var(kind), path)
    end
  end

  @spec put_opt(keyword(), atom()) :: keyword()
  def put_opt(opts, kind) when is_list(opts) do
    spec = spec!(kind)
    opts = drop_minted_option(opts, spec.option, kind)

    case path(opts, kind) do
      nil -> opts
      path -> Keyword.put(opts, spec.option, path)
    end
  end

  # Drop only the launch override we minted, while ownership can still be
  # checked. A later launch must allocate a live home rather than reuse a
  # deleted path that now looks like a caller override.
  @spec release_opt(keyword(), atom()) :: keyword()
  def release_opt(opts, kind) do
    option = spec!(kind).option
    next_opts = drop_minted_option(opts, option, kind)
    release(opts, kind)
    next_opts
  end

  @spec release(keyword(), atom()) :: :ok
  def release(opts, kind) when is_list(opts) do
    spec = spec!(kind)
    key = cache_key(opts, kind)

    cached =
      case Process.delete(key) do
        path when is_binary(path) -> path
        _ -> nil
      end

    configured = configured_path(opts, spec)
    option = option_path(opts, spec)

    [cached, configured, option]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.each(&remove_minted(&1, kind))

    :ok
  end

  def release(_opts, _kind), do: :ok

  defp configured_path(opts, spec) do
    case option_path(opts, spec) do
      path when is_binary(path) ->
        path

      nil ->
        case env_get(Keyword.get(opts, :env, []), spec.env) do
          path when is_binary(path) and path != "" -> Path.expand(path)
          _ -> nil
        end
    end
  end

  defp option_path(opts, spec) do
    case Keyword.get(opts, spec.option) do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> nil
    end
  end

  defp env_get(env, name) do
    env
    |> normalize_env()
    |> Map.get(name)
    |> env_string()
  end

  defp normalize_env(env) when is_map(env) do
    Map.new(env, fn {key, value} -> {to_string(key), env_string(value)} end)
  end

  defp normalize_env(env) when is_list(env) do
    Enum.reduce(env, %{}, fn
      {key, value}, acc ->
        Map.put(acc, to_string(key), env_string(value))

      %{"name" => name, "value" => value}, acc ->
        Map.put(acc, to_string(name), env_string(value))

      %{name: name, value: value}, acc ->
        Map.put(acc, to_string(name), env_string(value))

      _other, acc ->
        acc
    end)
  end

  defp normalize_env(_env), do: %{}

  defp env_string(value) when is_binary(value), do: value
  defp env_string(value) when is_list(value), do: List.to_string(value)
  defp env_string(_value), do: nil

  defp drop_minted_option(opts, option, kind) do
    case Keyword.get(opts, option) do
      path when is_binary(path) ->
        if owned_path?(path, kind), do: Keyword.delete(opts, option), else: opts

      _ ->
        opts
    end
  end

  defp owned_path?(path, kind) do
    case Map.get(Process.get(@owned_key, %{}), path) do
      {^kind, identity, _watcher} -> same_directory?(path, identity)
      _caller_owned -> false
    end
  end

  defp same_directory?(path, {device, inode}) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, major_device: ^device, inode: ^inode}} -> true
      _changed_or_missing -> false
    end
  end

  defp spec!(kind) do
    case Map.fetch(@kinds, kind) do
      {:ok, spec} -> spec
      :error -> raise ArgumentError, "unknown runtime home #{inspect(kind)}"
    end
  end

  defp session_key(opts) do
    case Keyword.get(opts, :_runtime_home_session) || Keyword.get(opts, :session_id) ||
           Keyword.get(opts, :resume) do
      id when is_binary(id) and id != "" -> id
      _ -> :connection
    end
  end

  defp cache_key(opts, kind), do: {__MODULE__, kind, session_key(opts)}

  defp cached_or_create(opts, kind) do
    key = cache_key(opts, kind)

    case Process.get(key) do
      path when is_binary(path) ->
        if owned_path?(path, kind) do
          prepare!(kind, path)
          path
        else
          remove_minted(path, kind)
          Process.delete(key)
          cached_or_create(opts, kind)
        end

      nil ->
        path = create!(kind)
        prepare!(kind, path)
        Process.put(key, path)
        path
    end
  end

  defp create!(kind) do
    case System.tmp_dir() do
      nil ->
        raise "cannot create a private #{kind} home: System.tmp_dir/0 is nil"

      tmp ->
        suffix = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        dir = Path.join(tmp, @dir_prefix <> "#{kind}_" <> suffix)

        case File.mkdir(dir) do
          :ok ->
            case File.chmod(dir, 0o700) do
              :ok ->
                info = File.lstat!(dir)
                identity = {info.major_device, info.inode}
                watcher = remove_when_down(self(), dir, identity)
                owned = Map.put(Process.get(@owned_key, %{}), dir, {kind, identity, watcher})
                Process.put(@owned_key, owned)
                dir

              {:error, reason} ->
                File.rm_rf(dir)
                raise "cannot chmod private #{kind} home: #{inspect(reason)}"
            end

          {:error, reason} ->
            raise "cannot create private #{kind} home: #{inspect(reason)}"
        end
    end
  end

  defp prepare!(:codex, path) do
    _ = File.rm(Path.join(path, "AGENTS.md"))
    config = Path.join(path, "config.toml")

    unless File.exists?(config) do
      File.write!(config, """
      project_doc_max_bytes = 0

      [features]
      skills = false
      """)

      _ = File.chmod(config, 0o600)
    end

    :ok
  end

  defp prepare!(_kind, _path), do: :ok

  defp remove_minted(path, kind) do
    case Map.get(Process.get(@owned_key, %{}), path) do
      {^kind, identity, watcher} ->
        removed = if same_directory?(path, identity), do: File.rm_rf(path), else: {:ok, []}

        if match?({:ok, _}, removed) do
          Process.exit(watcher, :shutdown)
          Process.put(@owned_key, Map.delete(Process.get(@owned_key, %{}), path))
        end

        for key <- Process.get_keys(path), match?({__MODULE__, ^kind, _session}, key) do
          Process.delete(key)
        end

      _caller_owned ->
        :ok
    end

    :ok
  end

  defp remove_when_down(owner, dir, identity) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} ->
          if same_directory?(dir, identity), do: File.rm_rf(dir)
      end
    end)
  end
end
