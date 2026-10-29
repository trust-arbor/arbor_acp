defmodule Arbor.ACP.Adapters.Internal.RuntimeHome do
  @moduledoc false

  # Private per-session config directories for vendor CLIs. Created 0700 under
  # System.tmp_dir/0 and removed when the process that requested them exits
  # (the AdapterBridge for a managed launch).

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
          cached_or_create(kind)
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

  defp spec!(kind) do
    case Map.fetch(@kinds, kind) do
      {:ok, spec} -> spec
      :error -> raise ArgumentError, "unknown runtime home #{inspect(kind)}"
    end
  end

  defp cached_or_create(kind) do
    key = {__MODULE__, kind}

    case Process.get(key) do
      path when is_binary(path) ->
        path

      nil ->
        path = create!(kind)
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
