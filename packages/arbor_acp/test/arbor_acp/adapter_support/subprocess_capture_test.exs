defmodule Arbor.ACP.AdapterSupport.SubprocessCaptureTest do
  use ExUnit.Case, async: false

  alias Arbor.ACP.AdapterSupport.Subprocess

  defmodule PolicyAdapter do
    def environment_defaults(_opts), do: %{"POLICY_VALUE" => "default", "POLICY_DEFAULT" => "yes"}
    def env(_opts), do: %{"POLICY_VALUE" => "adapter", "POLICY_ADAPTER" => "yes"}
  end

  setup do
    directory =
      Path.join(System.tmp_dir!(), "arbor-policy-capture-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    {physical_directory, 0} = System.cmd("/bin/pwd", ["-P"], cd: directory)
    directory = String.trim(physical_directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  test "utility capture applies adapter defaults and explicit environment in the child cwd", %{
    directory: directory
  } do
    inherited = System.get_env("CAPTURE_HOST_SECRET")
    System.put_env("CAPTURE_HOST_SECRET", "host-secret")

    on_exit(fn ->
      if inherited,
        do: System.put_env("CAPTURE_HOST_SECRET", inherited),
        else: System.delete_env("CAPTURE_HOST_SECRET")
    end)

    cli = Path.join(directory, "utility")

    File.write!(cli, """
    #!/bin/sh
    printf '%s|%s|%s|%s|%s|%s|%s|%s' "$PWD" "$POLICY_VALUE" "$POLICY_DEFAULT" "$POLICY_ADAPTER" "$TERM" "${MIX_ENV-unset}" "${CAPTURE_HOST_SECRET-unset}" "${EXPLICIT_UNSET-unset}"
    """)

    File.chmod!(cli, 0o755)

    assert {:ok, output, 0} =
             Subprocess.capture(
               "utility",
               [],
               [
                 cwd: directory,
                 env: %{"PATH" => ".", "POLICY_VALUE" => "caller", "EXPLICIT_UNSET" => false}
               ],
               PolicyAdapter
             )

    assert output == "#{directory}|caller|yes|yes|dumb|unset|unset|unset"
  end

  test "returns utility status and merged stderr; preserves byte overflow errors" do
    assert {:ok, "out\nerr", 7} =
             Subprocess.capture(
               "/bin/sh",
               ["-c", "printf 'out\\n'; printf err >&2; exit 7"],
               [],
               PolicyAdapter
             )

    assert {:error, :output_too_large} =
             Subprocess.capture(
               "/usr/bin/printf",
               ["123456"],
               [max_output_bytes: 5],
               PolicyAdapter
             )
  end

  test "deadline expiry reaps the utility without a timed Task", %{directory: directory} do
    marker = Path.join(directory, "pid")

    assert {:error, :timeout} =
             Subprocess.capture(
               "/bin/sh",
               ["-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "fixture", marker],
               [timeout: 500, cleanup_timeout: 200, term_grace: 50],
               PolicyAdapter
             )

    pid = marker |> File.read!() |> String.trim()

    eventually(fn ->
      {_output, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
      status != 0
    end)
  end

  defp eventually(predicate, attempts \\ 100)

  defp eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end

  defp eventually(_predicate, 0), do: flunk("utility did not stop")
end
