defmodule Arbor.ACP.Adapters.Internal.RuntimeHome do
  @moduledoc false
  require Logger
  alias Arbor.ACP.Adapters.Internal.PrivateKeychain

  # Private config directories for vendor CLIs, created 0700 under tmp.
  # Claude/Codex use a connection home; Pi also allocates child launch scopes.
  # Explicit cleanup and an owner monitor retire generated directories. A caller :env vendor var or explicit option is the source of
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
    case Map.fetch(normalize_env(Keyword.get(opts, :env, [])), name) do
      {:ok, value} when is_binary(value) and value != "" ->
        value

      {:ok, _unset} ->
        nil

      :error ->
        if Keyword.get(opts, :environment_policy) == :inherit do
          case System.get_env(name) do
            value when is_binary(value) and value != "" -> value
            _ -> nil
          end
        end
    end
  end

  def env_value(_opts, _name), do: nil

  @spec path(keyword(), atom()) :: String.t() | nil
  def path(opts, kind) when is_list(opts) do
    spec = spec!(kind)
    validate_home_env!(opts, spec)
    validate_profile_env!(opts, kind)

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

  defp validate_home_env!(opts, spec) do
    env = normalize_env(Keyword.get(opts, :env, []))

    if not trust_workspace_config?(opts) and Map.has_key?(env, spec.env) and
         Map.get(env, spec.env) in [nil, ""] do
      raise ArgumentError,
            "#{spec.env} must be a nonempty home path when workspace isolation is enabled"
    end
  end

  defp validate_profile_env!(opts, :claude) do
    home = configured_path(opts, spec!(:claude))
    isolated? = not trust_workspace_config?(opts) and (is_nil(home) or owned_path?(home, :claude))
    supplied = normalize_env(Keyword.get(opts, :env, []))

    if isolated? and Map.has_key?(supplied, "ANTHROPIC_CONFIG_DIR") and
         Map.get(supplied, "ANTHROPIC_CONFIG_DIR") in [nil, ""] do
      raise ArgumentError,
            "ANTHROPIC_CONFIG_DIR must be a nonempty path when workspace isolation is enabled"
    end
  end

  defp validate_profile_env!(_opts, _kind), do: :ok

  @spec put(map(), keyword(), atom()) :: map()
  def put(env, opts, kind) when is_map(env) do
    case path(opts, kind) do
      nil ->
        env

      path ->
        env = Map.put(env, env_var(kind), path)
        if kind == :claude, do: put_auth_profile(env, opts, path), else: env
    end
  end

  @spec put_opt(keyword(), atom()) :: keyword()
  def put_opt(opts, kind) when is_list(opts) do
    spec = spec!(kind)
    opts = drop_minted_option(opts, spec.option, kind)
    path = path(opts, kind)
    supplied = normalize_env(Keyword.get(opts, :env, []))

    opts =
      cond do
        path -> Keyword.put(opts, spec.option, path)
        Map.has_key?(supplied, spec.env) -> Keyword.delete(opts, spec.option)
        true -> opts
      end

    opts =
      if is_binary(Map.get(supplied, spec.env)) and Map.get(supplied, spec.env) != "" do
        Keyword.put(opts, :env, Map.put(supplied, spec.env, path))
      else
        opts
      end

    if kind == :claude do
      opts =
        if path && owned_path?(path, :claude),
          do: Keyword.put_new(opts, :_anthropic_auth_dir, Path.join(path, "anthropic")),
          else: opts

      supplied = normalize_env(Keyword.get(opts, :env, []))

      case Map.fetch(supplied, "ANTHROPIC_CONFIG_DIR") do
        {:ok, profile} when is_binary(profile) and profile != "" ->
          Keyword.put(
            opts,
            :env,
            Map.put(supplied, "ANTHROPIC_CONFIG_DIR", profile_path(profile, opts))
          )

        :error ->
          if not owned_path?(path, :claude) do
            case env_value(opts, "ANTHROPIC_CONFIG_DIR") do
              profile when is_binary(profile) ->
                Keyword.put(
                  opts,
                  :env,
                  Map.put(supplied, "ANTHROPIC_CONFIG_DIR", profile_path(profile, opts))
                )

              _ ->
                opts
            end
          else
            opts
          end

        _unset ->
          opts
      end
    else
      opts
    end
  end

  def owned?(opts, kind) do
    case configured_path(opts, spec!(kind)) do
      path when is_binary(path) -> owned_path?(path, kind)
      _ -> false
    end
  end

  defp put_auth_profile(env, opts, home) do
    if owned_path?(home, :claude) do
      supplied = normalize_env(Keyword.get(opts, :env, []))

      case Map.fetch(supplied, "ANTHROPIC_CONFIG_DIR") do
        {:ok, value} when value in [nil, ""] ->
          raise ArgumentError,
                "ANTHROPIC_CONFIG_DIR must be a nonempty path when workspace isolation is enabled"

        {:ok, path} ->
          Map.put(env, "ANTHROPIC_CONFIG_DIR", profile_path(path, opts))

        :error ->
          Map.put(
            env,
            "ANTHROPIC_CONFIG_DIR",
            Keyword.get(opts, :_anthropic_auth_dir, Path.join(home, "anthropic"))
          )
      end
    else
      env
    end
  end

  defp profile_path(path, opts) do
    cwd = Keyword.get(opts, :cwd) || Keyword.get(opts, :cd) || File.cwd!()
    Path.expand(path, Path.expand(cwd))
  end

  def track_keychain(opts) do
    path = configured_path(opts, spec!(:claude))

    if is_binary(path) and owned_path?(path, :claude) do
      {_kind, _identity, watcher} = Map.fetch!(Process.get(@owned_key), path)
      capture = PrivateKeychain.runner()
      Process.put({__MODULE__, :keychain, path}, capture)
      send(watcher, {:track_keychain, capture})
    end

    :ok
  end

  # Drop only the launch override we minted, while ownership can still be
  # checked. A later launch must allocate a live home rather than reuse a
  # deleted path that now looks like a caller override.
  # Only auth material from our private login home is carried into another
  # generated home. Caller homes, workspace config, transcripts and settings
  # are never copied. New children can use the login advertised at initialize.
  def seed_auth(source_opts, target_opts, kind),
    do: transfer_auth(source_opts, target_opts, kind, :seed)

  def refresh_auth(source_opts, target_opts, kind),
    do: transfer_auth(source_opts, target_opts, kind, :refresh)

  defp transfer_auth(source_opts, target_opts, kind, mode) do
    source = configured_path(source_opts, spec!(kind))
    target = configured_path(target_opts, spec!(kind))

    if is_binary(source) and is_binary(target) and source != target and
         owned_path?(source, kind) and owned_path?(target, kind) do
      Enum.reduce_while(auth_files(kind), :ok, fn name, :ok ->
        case copy_auth_file(Path.join(source, name), Path.join(target, name), mode) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      :ok
    end
  end

  defp auth_files(:claude), do: [".credentials.json"]
  defp auth_files(:pi), do: ["auth.json"]
  defp auth_files(_kind), do: []

  defp copy_auth_file(source, target, mode) do
    case File.lstat(source) do
      {:ok, %File.Stat{type: :regular}} ->
        with {:ok, data} <- File.read(source) do
          write_auth_file(target, data, mode)
        end

      {:error, :enoent} ->
        :ok

      {:ok, _not_regular} ->
        {:error, :invalid_auth_file}

      {:error, _} = error ->
        error
    end
  end

  defp write_auth_file(target, data, :seed) do
    case File.open(target, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result = with :ok <- File.chmod(target, 0o600), do: IO.binwrite(io, data)
        closed = File.close(io)
        if result == :ok, do: closed, else: result

      {:error, :eexist} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp write_auth_file(target, data, :refresh) do
    suffix = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    temp = target <> ".refresh-" <> suffix

    try do
      with :ok <- write_auth_file(temp, data, :seed), do: File.rename(temp, target)
    after
      File.rm(temp)
    end
  end

  @spec release_opt(keyword(), atom()) :: keyword() | {:error, term()}
  def release_opt(opts, kind) do
    option = spec!(kind).option
    next_opts = drop_minted_option(opts, option, kind)

    case release(opts, kind) do
      :ok -> next_opts
      {:error, _} = error -> error
    end
  end

  @spec release(keyword(), atom()) :: :ok | {:error, term()}
  def release(opts, kind) when is_list(opts) do
    spec = spec!(kind)
    key = cache_key(opts, kind)

    cached =
      case Process.get(key) do
        path when is_binary(path) -> path
        _ -> nil
      end

    configured = configured_path(opts, spec)

    supplied? =
      Map.has_key?(normalize_env(Keyword.get(opts, :env, [])), spec.env) or
        option_path(opts, spec) != nil

    selected = if supplied?, do: configured, else: cached

    [selected]
    |> Enum.filter(&is_binary/1)
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case remove_minted(path, kind) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def release(_opts, _kind), do: :ok

  defp configured_path(opts, spec) do
    # Caller :env has the final say in Subprocess. Use that same path for
    # storage, terminal login and cleanup, and anchor relative env paths to cwd.
    case Map.fetch(normalize_env(Keyword.get(opts, :env, [])), spec.env) do
      {:ok, path} when is_binary(path) and path != "" -> profile_path(path, opts)
      {:ok, _unset} -> nil
      :error -> option_path(opts, spec)
    end
  end

  defp option_path(opts, spec) do
    case Keyword.get(opts, spec.option) do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> nil
    end
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
        result =
          if same_directory?(path, identity) do
            with :ok <- cleanup_keychain(path, Process.get({__MODULE__, :keychain, path})) do
              case File.rm_rf(path) do
                {:ok, _} -> :ok
                {:error, reason, _file} -> {:error, {:private_home_cleanup_failed, reason}}
              end
            end
          else
            :ok
          end

        if result == :ok do
          Process.exit(watcher, :shutdown)
          Process.put(@owned_key, Map.delete(Process.get(@owned_key, %{}), path))
          Process.delete({__MODULE__, :keychain, path})

          for key <- Process.get_keys(path),
              match?({__MODULE__, ^kind, _session}, key),
              do: Process.delete(key)
        end

        result

      _caller_owned ->
        :ok
    end
  end

  defp cleanup_keychain(_path, nil), do: :ok
  defp cleanup_keychain(path, capture), do: PrivateKeychain.cleanup(path, capture)

  defp remove_when_down(owner, dir, identity) do
    spawn(fn -> wait_for_owner(Process.monitor(owner), dir, identity, nil) end)
  end

  defp wait_for_owner(ref, dir, identity, capture) do
    receive do
      {:track_keychain, runner} ->
        wait_for_owner(ref, dir, identity, runner)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        if same_directory?(dir, identity) do
          case cleanup_keychain(dir, capture) do
            :ok ->
              File.rm_rf(dir)

            {:error, _} ->
              Logger.warning("Private Claude credential cleanup could not be confirmed")
          end
        end
    end
  end
end
