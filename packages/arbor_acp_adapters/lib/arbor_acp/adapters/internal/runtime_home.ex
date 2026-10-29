defmodule Arbor.ACP.Adapters.Internal.RuntimeHome do
  @moduledoc false

  # Private per-session config directories for vendor CLIs. Created 0700 under
  # System.tmp_dir/0 and removed when the process that requested them exits
  # (the AdapterBridge for a managed launch). Cached per vendor and workspace
  # so a later session with a different cwd does not reuse the previous home.

  @dir_prefix "arbor_acp_runtime_home_"

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

  @spec path(keyword(), atom()) :: String.t() | nil
  def path(opts, kind) when is_list(opts) do
    spec = spec!(kind)

    case Keyword.get(opts, spec.option) do
      path when is_binary(path) and path != "" ->
        Path.expand(path)

      _ ->
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
    opts = drop_minted_option(opts, spec.option)

    case path(opts, kind) do
      nil -> opts
      path -> Keyword.put(opts, spec.option, path)
    end
  end

  defp drop_minted_option(opts, option) do
    case Keyword.get(opts, option) do
      path when is_binary(path) ->
        if minted_path?(path), do: Keyword.delete(opts, option), else: opts

      _ ->
        opts
    end
  end

  defp minted_path?(path) do
    String.starts_with?(Path.basename(path), @dir_prefix)
  end

  defp spec!(kind) do
    case Map.fetch(@kinds, kind) do
      {:ok, spec} -> spec
      :error -> raise ArgumentError, "unknown runtime home #{inspect(kind)}"
    end
  end

  defp session_key(opts) do
    case Keyword.get(opts, :cwd) do
      cwd when is_binary(cwd) and cwd != "" -> Path.expand(cwd)
      _ -> :connection
    end
  end

  defp cached_or_create(opts, kind) do
    key = {__MODULE__, kind, session_key(opts)}

    case Process.get(key) do
      path when is_binary(path) ->
        prepare!(kind, path)
        path

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
                remove_when_down(self(), dir)
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
    config = Path.join(path, "config.toml")

    unless File.exists?(config) do
      File.write!(config, "project_doc_max_bytes = 0\n")
      _ = File.chmod(config, 0o600)
    end

    :ok
  end

  defp prepare!(_kind, _path), do: :ok

  defp remove_when_down(owner, dir) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> File.rm_rf(dir)
      end
    end)

    :ok
  end
end
