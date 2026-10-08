defmodule Arbor.ACP.AdapterSupport.Subprocess do
  @moduledoc """
  Adapter policy over the shared owned subprocess mechanics.

  `open/4` returns an opaque shared handle and subscribes its lifetime owner
  with one frame of credit. The owner acknowledges after it has admitted the
  translated messages to a bounded destination. Native protocol decoding stays
  with the adapter. Matching closure reports the unfinished frame's original
  bytes so the adapter can process a final message before failing pending work.
  """

  alias Arbor.RPC.{FramedStream, PortEnvironment, Subprocess}

  @runtime_vars_to_clear ~w(MIX_ENV MIX_TARGET)

  @spec open(String.t(), [String.t()], keyword(), module()) ::
          {:ok, Subprocess.t()} | {:error, term()}
  def open(cmd, args, opts, adapter_mod) do
    owner = Keyword.get(opts, :owner, self())

    child_opts = child_options(opts, adapter_mod)

    with {:ok, child} <- Subprocess.open([cmd | args], child_opts) do
      case FramedStream.subscribe(child, owner, window: 1) do
        :ok ->
          {:ok, child}

        {:error, reason} ->
          cleanup = Subprocess.close(child)
          {:error, {:subscribe_failed, reason, cleanup}}
      end
    end
  end

  @doc """
  Captures a bounded utility command with the adapter's environment policy.

  Adapter defaults, `env/1` and caller `:env` use the same precedence as `open/4`.
  Stderr is combined by default. The capturing caller owns the child, and
  `:timeout` / `:max_output_bytes` default to 5 seconds / 1 MiB. Nonzero status
  returns `{:ok, output, status}`; pressure, timeout and known cleanup failures
  return explicit errors. Original line endings and EOF remainder are preserved.
  """
  @spec capture(String.t(), [String.t()], keyword(), module()) ::
          {:ok, binary(), non_neg_integer()} | {:error, term()}
  def capture(cmd, args, opts, adapter_mod) do
    Subprocess.capture([cmd | args], child_options(opts, adapter_mod))
  end

  defp child_options(opts, adapter_mod) do
    opts
    |> Keyword.put(:cd, Keyword.get(opts, :cwd, Keyword.get(opts, :cd, File.cwd!())))
    |> Keyword.put(:env, environment_overrides(opts, adapter_mod))
    |> Keyword.put_new(:stderr_to_stdout, true)
  end

  @spec command(Subprocess.t(), iodata()) :: :ok | {:error, term()}
  def command(child, data), do: Subprocess.write(child, data)

  @spec close(Subprocess.t() | nil) :: :ok | {:error, term()}
  def close(child), do: Subprocess.close(child)

  @spec identity(Subprocess.t()) :: reference()
  def identity(child), do: Subprocess.identity(child)

  @spec connected?(Subprocess.t() | nil) :: boolean()
  def connected?(nil), do: false
  def connected?(child), do: Subprocess.connected?(child)

  @spec ack(Subprocess.t(), reference()) :: :ok | {:error, term()}
  def ack(child, token), do: FramedStream.ack(child, token)

  @spec event(Subprocess.t() | nil, term()) ::
          {:frame, reference(), binary()} | {:closed, term(), binary()} | :ignore
  def event(nil, _message), do: :ignore

  def event(child, {:arbor_rpc, generation, {:frame, token, bytes}}) do
    if generation == identity(child), do: {:frame, token, bytes}, else: :ignore
  end

  def event(child, {:arbor_rpc, generation, {:closed, reason, remainder}}) do
    if generation == identity(child), do: {:closed, reason, remainder}, else: :ignore
  end

  def event(_child, _message), do: :ignore

  @spec safe_env(keyword(), module()) :: [{charlist(), charlist() | false}]
  def safe_env(opts, adapter_mod) do
    opts
    |> PortEnvironment.base()
    |> Map.merge(environment_overrides(opts, adapter_mod))
    |> PortEnvironment.to_port()
  end

  defp environment_overrides(opts, adapter_mod) do
    %{}
    |> Map.merge(Map.new(@runtime_vars_to_clear, &{&1, false}))
    |> Map.put("TERM", "dumb")
    |> Map.merge(adapter_environment_defaults(opts, adapter_mod))
    |> Map.merge(adapter_env(opts, adapter_mod))
  end

  defp adapter_environment_defaults(opts, adapter_mod) do
    if Code.ensure_loaded?(adapter_mod) and
         function_exported?(adapter_mod, :environment_defaults, 1),
       do: adapter_mod.environment_defaults(opts) |> PortEnvironment.normalize(),
       else: %{}
  end

  defp adapter_env(opts, adapter_mod) do
    adapter_default_env =
      if Code.ensure_loaded?(adapter_mod) and function_exported?(adapter_mod, :env, 1) do
        adapter_mod.env(opts)
      else
        []
      end

    adapter_default_env
    |> PortEnvironment.normalize()
    |> Map.merge(opts |> Keyword.get(:env, []) |> PortEnvironment.normalize())
  end
end
