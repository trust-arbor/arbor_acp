defmodule ArchiveConsumer do
  @moduledoc false

  def probe do
    {:ok, _} = Application.ensure_all_started(:archive_consumer)
    # This is run both from an installed Mix application and an assembled
    # release. Executables below are absolute; a runtime compiler is unavailable.
    System.put_env("PATH", "/no-runtime-compiler")
    System.put_env("CC", "/compiler-must-not-run")
    nil = System.find_executable("cc")

    priv = :arbor_rpc |> :code.priv_dir() |> List.to_string()
    true = File.regular?(Path.join(priv, "native/arbor_rpc_subprocess"))

    {:ok, "installed-final\r\nlast", 7} =
      Arbor.RPC.Subprocess.capture([
        "/bin/sh",
        "-c",
        "printf 'installed-final\\r\\nlast'; exit 7"
      ])

    {:ok, child} = Arbor.RPC.Subprocess.open(["/bin/sleep", "30"], process_group: true)
    :ok = Arbor.RPC.Subprocess.close(child)

    {:ok, %{direct_child: :reaped, targeted_group: :absent}} =
      Arbor.RPC.Subprocess.cleanup_receipt(child)

    :ok = Arbor.RPC.Subprocess.close(child)
    apps = Application.started_applications() |> Enum.map(&elem(&1, 0))
    true = Enum.all?([:arbor_rpc, :arbor_acp, :arbor_acp_adapters], &(&1 in apps))

    IO.puts(
      "Archive apps, installed helper, exact bytes/status and retained cleanup receipt pass"
    )
  end
end
