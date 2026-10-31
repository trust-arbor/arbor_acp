defmodule Arbor.ACP.Adapters.PrivateKeychainTest do
  use ExUnit.Case, async: true
  alias Arbor.ACP.Adapters.Internal.{PrivateKeychain, RuntimeHome}

  test "only the two hashed services for the exact generated path are deleted" do
    home = "/private/tmp/acp-home"
    suffix = :crypto.hash(:sha256, home) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    parent = self()

    capture = fn args ->
      send(parent, {:capture, args})
      {:ok, "discarded", 0}
    end

    assert :ok = PrivateKeychain.cleanup(home, capture)

    assert_receive {:capture,
                    ["delete-generic-password", "-s", "Claude Code-credentials-" <> ^suffix]}

    assert_receive {:capture, ["delete-generic-password", "-s", "Claude Code-" <> ^suffix]}
    refute PrivateKeychain.services(home) == PrivateKeychain.services(home <> "/")
  end

  test "missing items succeed and failures never include subprocess output" do
    assert :ok = PrivateKeychain.cleanup("/private/tmp/missing", fn _ -> {:ok, "", 44} end)

    for capture <- [
          fn _ -> {:ok, "secret output", 1} end,
          fn _ -> raise "secret exception" end,
          fn _ -> {:error, :timeout} end
        ] do
      assert {:error, :private_keychain_cleanup_unconfirmed} =
               PrivateKeychain.cleanup("/private/tmp/failure", capture)
    end
  end

  test "failed explicit cleanup retains the generated home and can be retried" do
    opts = RuntimeHome.put_opt([], :claude)
    home = opts[:claude_config_dir]

    PrivateKeychain.with_runner(fn _ -> {:ok, "ignored", 1} end, fn ->
      RuntimeHome.track_keychain(opts)
    end)

    assert {:error, :private_keychain_cleanup_unconfirmed} =
             RuntimeHome.release_opt(opts, :claude)

    assert File.dir?(home)
    assert RuntimeHome.path([], :claude) == home

    PrivateKeychain.with_runner(fn _ -> {:ok, "", 44} end, fn ->
      RuntimeHome.track_keychain(opts)
    end)

    assert :ok = RuntimeHome.release(opts, :claude)
    refute File.exists?(home)
  end

  test "caller-owned homes never register credential cleanup" do
    home =
      Path.join(
        System.tmp_dir!(),
        "arbor_acp_runtime_home_caller_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    parent = self()

    PrivateKeychain.with_runner(
      fn args ->
        send(parent, {:unexpected, args})
        {:ok, "", 0}
      end,
      fn ->
        opts = [claude_config_dir: home]
        RuntimeHome.track_keychain(opts)
        assert :ok = RuntimeHome.release(opts, :claude)
      end
    )

    assert File.dir?(home)
    refute_receive {:unexpected, _}
  end

  test "owner exit uses the captured fake cleanup before removing its home" do
    parent = self()

    owner =
      spawn(fn ->
        opts = RuntimeHome.put_opt([], :claude)
        home = opts[:claude_config_dir]

        PrivateKeychain.with_runner(
          fn args ->
            send(parent, {:deleted, args})
            {:ok, "", 0}
          end,
          fn ->
            RuntimeHome.track_keychain(opts)
          end
        )

        {_, _, watcher} = Process.get({RuntimeHome, :owned_homes})[home]
        send(parent, {:owned, home, watcher})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:owned, home, watcher}
    ref = Process.monitor(watcher)
    send(owner, :finish)
    assert_receive {:deleted, ["delete-generic-password", "-s", _]}
    assert_receive {:deleted, ["delete-generic-password", "-s", _]}
    assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}
    refute File.exists?(home)
  end

  test "Claude terminal auth uses the initialized home and exposes cleanup failures for retry" do
    alias Arbor.ACP.Adapters.ClaudeSDK
    {:ok, state} = ClaudeSDK.init([])
    state = %{state | client_capabilities: %{"auth" => %{"terminal" => true}}}
    home = state.opts[:claude_config_dir]

    PrivateKeychain.with_runner(fn _ -> {:ok, "secret output", 1} end, fn ->
      for method <- ClaudeSDK.auth_methods([], state) do
        assert method["env"]["CLAUDE_CONFIG_DIR"] == home
        assert method["env"]["ANTHROPIC_CONFIG_DIR"] == Path.join(home, "anthropic")
      end
    end)

    assert {:error, :private_keychain_cleanup_unconfirmed, failed} = ClaudeSDK.shutdown(state)
    assert File.dir?(home)
    assert failed.cleanup_result == {:error, :private_keychain_cleanup_unconfirmed}

    PrivateKeychain.with_runner(fn _ -> {:ok, "", 44} end, fn ->
      RuntimeHome.track_keychain(failed.opts)
    end)

    assert {:ok, closed} = ClaudeSDK.shutdown(failed)
    assert closed.cleanup_result == :ok
    refute File.exists?(home)
  end

  test "generated Claude homes also isolate implicit Anthropic profiles" do
    opts = RuntimeHome.put_opt([], :claude)
    env = RuntimeHome.put(%{}, opts, :claude)
    assert env["ANTHROPIC_CONFIG_DIR"] == Path.join(opts[:claude_config_dir], "anthropic")

    for value <- [false, nil, ""] do
      assert_raise ArgumentError, ~r/ANTHROPIC_CONFIG_DIR must be a nonempty path/, fn ->
        RuntimeHome.put(%{}, Keyword.put(opts, :env, [{"ANTHROPIC_CONFIG_DIR", value}]), :claude)
      end
    end

    explicit = Keyword.put(opts, :env, [{"ANTHROPIC_CONFIG_DIR", "/host/profiles"}])
    assert RuntimeHome.put(%{}, explicit, :claude)["ANTHROPIC_CONFIG_DIR"] == "/host/profiles"

    refute Map.has_key?(
             RuntimeHome.put(%{}, [claude_config_dir: "/host/claude"], :claude),
             "ANTHROPIC_CONFIG_DIR"
           )

    RuntimeHome.release(opts, :claude)
  end
end
