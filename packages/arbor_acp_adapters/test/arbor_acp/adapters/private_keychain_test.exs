defmodule Arbor.ACP.Adapters.PrivateKeychainTest do
  use ExUnit.Case, async: false
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

  for home_scope <- [:generated, :caller_owned] do
    @home_scope home_scope
    test "#{home_scope} profile overrides identify the same directory across child cwd changes" do
      alias Arbor.ACP.Adapters.ClaudeSDK
      alias Arbor.ACP.AdapterSupport.Subprocess

      root =
        Path.join(System.tmp_dir!(), "acp_profile_path_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(root, "workspace"))
      on_exit(fn -> File.rm_rf!(root) end)
      caller_home = Path.join(root, "caller-home")
      File.mkdir_p!(caller_home)
      opts = [cwd: root, env: [{"ANTHROPIC_CONFIG_DIR", "profiles"}]]

      opts =
        if @home_scope == :caller_owned,
          do: Keyword.put(opts, :claude_config_dir, caller_home),
          else: opts

      {:ok, state} = ClaudeSDK.init(opts)
      state = %{state | client_capabilities: %{"auth" => %{"terminal" => true}}}

      [method | _] =
        PrivateKeychain.with_runner(fn _ -> {:ok, "", 44} end, fn ->
          ClaudeSDK.auth_methods(opts, state)
        end)

      profile = Path.join(root, "profiles")
      assert method["env"]["ANTHROPIC_CONFIG_DIR"] == profile
      # Managed children may switch workspaces; the connection's auth override stays fixed.
      child_opts = Keyword.put(state.opts, :cwd, Path.join(root, "workspace"))

      assert {:ok, ^profile, 0} =
               Subprocess.capture(
                 "/bin/sh",
                 ["-c", ~s(printf '%s' "$ANTHROPIC_CONFIG_DIR")],
                 child_opts,
                 ClaudeSDK
               )

      # Unmanaged bridge launch retains the original environment's relative value,
      # which the CLI resolves against the bridge's configured child cwd.
      assert {:ok, relative, 0} =
               Subprocess.capture(
                 "/bin/sh",
                 ["-c", ~s(printf '%s' "$ANTHROPIC_CONFIG_DIR")],
                 opts,
                 ClaudeSDK
               )

      assert Path.expand(relative, root) == profile
      assert {:ok, _} = ClaudeSDK.shutdown(state)
    end
  end

  test "inherited ambient profiles cannot replace a generated terminal login profile" do
    alias Arbor.ACP.Adapters.ClaudeSDK
    previous = System.get_env("ANTHROPIC_CONFIG_DIR")
    System.put_env("ANTHROPIC_CONFIG_DIR", "/ambient/profile-must-not-be-used")

    on_exit(fn ->
      if previous,
        do: System.put_env("ANTHROPIC_CONFIG_DIR", previous),
        else: System.delete_env("ANTHROPIC_CONFIG_DIR")
    end)

    {:ok, state} = ClaudeSDK.init(environment_policy: :inherit)
    state = %{state | client_capabilities: %{"auth" => %{"terminal" => true}}}

    [method | _] =
      PrivateKeychain.with_runner(fn _ -> {:ok, "", 44} end, fn ->
        ClaudeSDK.auth_methods([], state)
      end)

    assert method["env"]["ANTHROPIC_CONFIG_DIR"] ==
             Path.join(state.opts[:claude_config_dir], "anthropic")

    assert ClaudeSDK.env(state.opts)["ANTHROPIC_CONFIG_DIR"] ==
             method["env"]["ANTHROPIC_CONFIG_DIR"]

    assert RuntimeHome.env_value(
             [environment_policy: :inherit, env: [{"ANTHROPIC_CONFIG_DIR", false}]],
             "ANTHROPIC_CONFIG_DIR"
           ) == nil

    assert {:ok, _} = ClaudeSDK.shutdown(state)
  end

  test "inherited caller-owned relative profiles stay anchored across workspace changes" do
    alias Arbor.ACP.Adapters.ClaudeSDK
    alias Arbor.ACP.AdapterSupport.Subprocess
    previous = System.get_env("ANTHROPIC_CONFIG_DIR")
    System.put_env("ANTHROPIC_CONFIG_DIR", "profiles")

    on_exit(fn ->
      if previous,
        do: System.put_env("ANTHROPIC_CONFIG_DIR", previous),
        else: System.delete_env("ANTHROPIC_CONFIG_DIR")
    end)

    root =
      Path.join(System.tmp_dir!(), "acp_inherited_profile_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "home"))
    File.mkdir_p!(Path.join(root, "workspace"))
    on_exit(fn -> File.rm_rf!(root) end)
    opts = [cwd: root, claude_config_dir: Path.join(root, "home"), environment_policy: :inherit]
    {:ok, state} = ClaudeSDK.init(opts)
    state = %{state | client_capabilities: %{"auth" => %{"terminal" => true}}}

    [method | _] =
      PrivateKeychain.with_runner(fn _ -> {:ok, "", 44} end, fn ->
        ClaudeSDK.auth_methods(opts, state)
      end)

    profile = Path.join(root, "profiles")
    assert method["env"]["ANTHROPIC_CONFIG_DIR"] == profile
    child = Keyword.put(state.opts, :cwd, Path.join(root, "workspace"))

    assert {:ok, ^profile, 0} =
             Subprocess.capture(
               "/bin/sh",
               ["-c", ~s(printf '%s' "$ANTHROPIC_CONFIG_DIR")],
               child,
               ClaudeSDK
             )

    assert {:ok, _} = ClaudeSDK.shutdown(state)
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
