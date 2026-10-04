defmodule Arbor.ACP.AdapterSupport.Subprocess do
  @moduledoc "Adapter subprocess support; shared subprocess convergence is pending."

  alias Arbor.RPC.PortEnvironment

  @runtime_vars_to_clear ~w(MIX_ENV MIX_TARGET)

  @spec open(String.t(), [String.t()], keyword(), module()) ::
          {:ok, port()} | {:error, term()}
  def open(cmd, args, opts, adapter_mod) do
    with :ok <- PortEnvironment.validate_policy(opts),
         executable when is_binary(executable) <- System.find_executable(cmd) do
      do_open(executable, args, opts, adapter_mod)
    else
      nil -> {:error, {:executable_not_found, cmd}}
      {:error, _reason} = error -> error
    end
  end

  defp do_open(executable, args, opts, adapter_mod) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      args: Enum.map(args, &to_charlist/1),
      cd: to_charlist(cwd),
      env: safe_env(opts, adapter_mod)
    ]

    try do
      port = Port.open({:spawn_executable, to_charlist(executable)}, port_opts)
      {:ok, port}
    catch
      :error, reason -> {:error, {:port_open_failed, reason}}
    end
  end

  @spec command(port(), iodata()) :: :ok | {:error, term()}
  def command(port, data) do
    Port.command(port, data)
    :ok
  catch
    :error, reason -> {:error, reason}
  end

  @spec close(port() | nil) :: :ok
  def close(nil), do: :ok

  def close(port) do
    Port.close(port)
    :ok
  catch
    :error, _ -> :ok
  end

  @spec safe_env(keyword(), module()) :: [{charlist(), charlist() | false}]
  def safe_env(opts, adapter_mod) do
    opts
    |> PortEnvironment.base()
    |> Map.merge(Map.new(@runtime_vars_to_clear, &{&1, false}))
    |> Map.put("TERM", "dumb")
    |> Map.merge(adapter_environment_defaults(opts, adapter_mod))
    |> Map.merge(adapter_env(opts, adapter_mod))
    |> PortEnvironment.to_port()
  end

  defp adapter_environment_defaults(opts, adapter_mod) do
    if function_exported?(adapter_mod, :environment_defaults, 1),
      do: adapter_mod.environment_defaults(opts) |> PortEnvironment.normalize(),
      else: %{}
  end

  defp adapter_env(opts, adapter_mod) do
    adapter_default_env =
      if function_exported?(adapter_mod, :env, 1) do
        adapter_mod.env(opts)
      else
        []
      end

    adapter_default_env
    |> PortEnvironment.normalize()
    |> Map.merge(opts |> Keyword.get(:env, []) |> PortEnvironment.normalize())
  end
end
