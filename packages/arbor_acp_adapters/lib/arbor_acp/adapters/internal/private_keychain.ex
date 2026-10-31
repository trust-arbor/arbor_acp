defmodule Arbor.ACP.Adapters.Internal.PrivateKeychain do
  @moduledoc false

  # Claude scopes production Keychain services to the exact config-dir value
  # using the first eight hex digits of SHA-256. Never address the unscoped
  # service: callers invoke this only for a generated home they still own.
  @runner_key {__MODULE__, :capture}

  def runner, do: Process.get(@runner_key, :native)

  def with_runner(capture, fun) when is_function(capture, 1) do
    previous = Process.get(@runner_key, :native)
    Process.put(@runner_key, capture)

    try do
      fun.()
    after
      Process.put(@runner_key, previous)
    end
  end

  def services(home) do
    suffix = :crypto.hash(:sha256, home) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    ["Claude Code-credentials-" <> suffix, "Claude Code-" <> suffix]
  end

  def cleanup(home, capture \\ :native) do
    if capture == :native and :os.type() != {:unix, :darwin} do
      :ok
    else
      Enum.reduce_while(services(home), :ok, fn service, :ok ->
        case run(["delete-generic-password", "-s", service], capture) do
          {:ok, _discarded_output, status} when status in [0, 44] -> {:cont, :ok}
          _unconfirmed -> {:halt, {:error, :private_keychain_cleanup_unconfirmed}}
        end
      end)
    end
  end

  defp run(args, :native) do
    Arbor.RPC.Subprocess.capture(["/usr/bin/security" | args],
      environment_policy: :hermetic,
      timeout: 5_000,
      cleanup_timeout: 500,
      max_output_bytes: 65_536
    )
  end

  defp run(args, capture) do
    capture.(args)
  catch
    _, _ -> {:error, :private_keychain_cleanup_unconfirmed}
  end
end
