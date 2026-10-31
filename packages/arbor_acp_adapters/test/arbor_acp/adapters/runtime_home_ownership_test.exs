defmodule Arbor.ACP.Adapters.RuntimeHomeOwnershipTest do
  use ExUnit.Case, async: true
  alias Arbor.ACP.Adapters.Internal.RuntimeHome

  @kinds [
    {:claude, :claude_config_dir, "CLAUDE_CONFIG_DIR"},
    {:codex, :codex_home, "CODEX_HOME"},
    {:pi, :agent_dir, "PI_CODING_AGENT_DIR"}
  ]

  setup do
    root =
      Path.join(System.tmp_dir!(), "acp_home_ownership_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for {kind, option, variable} <- @kinds, form <- [:option, :env] do
    @kind kind
    @option option
    @variable variable
    @form form
    test "#{kind} preserves a caller-owned home with the generated prefix through #{form}", %{
      root: root
    } do
      home = Path.join(root, "arbor_acp_runtime_home_caller_owned")
      File.mkdir_p!(home)
      marker = Path.join(home, "caller-data")
      File.write!(marker, "keep")
      opts = if @form == :option, do: [{@option, home}], else: [env: [{@variable, home}]]
      opts = Keyword.put(opts, :session_id, "caller")
      launch = RuntimeHome.put_opt(opts, @kind)
      assert Keyword.fetch!(launch, @option) == home
      assert :ok = RuntimeHome.release(launch, @kind)
      assert File.read!(marker) == "keep"
    end
  end

  test "releasing a generated home clears its cached path and leaves another session live" do
    first = RuntimeHome.put_opt([session_id: "first"], :claude)
    second = RuntimeHome.put_opt([session_id: "second"], :claude)
    home = Keyword.fetch!(first, :claude_config_dir)
    other = Keyword.fetch!(second, :claude_config_dir)
    assert home != other
    assert :ok = RuntimeHome.release(first, :claude)
    refute File.exists?(home)
    assert File.dir?(other)
    assert RuntimeHome.path([session_id: "first"], :claude) != home
  end

  test "a replacement at a generated path is not prepared or deleted as owned" do
    opts = [session_id: "replaced"]
    home = RuntimeHome.path(opts, :codex)
    saved = home <> ".saved"
    File.rename!(home, saved)
    File.mkdir!(home)
    File.write!(Path.join(home, "AGENTS.md"), "caller instructions")

    on_exit(fn ->
      File.rm_rf!(saved)
      File.rm_rf!(home)
    end)

    replacement = RuntimeHome.path(opts, :codex)
    assert replacement != home
    assert File.read!(Path.join(home, "AGENTS.md")) == "caller instructions"
    assert :ok = RuntimeHome.release(opts, :codex)
    assert File.read!(Path.join(home, "AGENTS.md")) == "caller instructions"
  end

  test "release_opt removes generated overrides before a subsequent launch" do
    opts = RuntimeHome.put_opt([], :pi)
    home = opts[:agent_dir]
    next_opts = RuntimeHome.release_opt(opts, :pi)
    refute Keyword.has_key?(next_opts, :agent_dir)
    refute File.exists?(home)
    next = RuntimeHome.put_opt(next_opts, :pi)
    assert next[:agent_dir] != home
    assert File.dir?(next[:agent_dir])
    RuntimeHome.release(next, :pi)
  end

  test "release_opt retains a caller override", %{root: root} do
    opts = [agent_dir: root]
    assert RuntimeHome.release_opt(opts, :pi) == opts
    assert File.dir?(root)
  end

  test "auth seeding copies only regular credential files between generated homes", %{root: root} do
    source = RuntimeHome.put_opt([], :claude)
    child = RuntimeHome.put_opt([_runtime_home_session: "child"], :claude)
    File.write!(Path.join(source[:claude_config_dir], ".credentials.json"), "temporary")
    File.write!(Path.join(source[:claude_config_dir], "settings.json"), "{}")
    assert :ok = RuntimeHome.seed_auth(source, child, :claude)
    assert File.read!(Path.join(child[:claude_config_dir], ".credentials.json")) == "temporary"
    refute File.exists?(Path.join(child[:claude_config_dir], "settings.json"))
    caller = [claude_config_dir: root]
    assert :ok = RuntimeHome.seed_auth(source, caller, :claude)
    refute File.exists?(Path.join(root, ".credentials.json"))
    RuntimeHome.release(source, :claude)
    RuntimeHome.release(child, :claude)
  end

  for {adapter, variable} <- [
        {Arbor.ACP.Adapters.ClaudeSDK, "CLAUDE_CONFIG_DIR"},
        {Arbor.ACP.Adapters.Codex, "CODEX_HOME"},
        {Arbor.ACP.Adapters.Pi, "PI_CODING_AGENT_DIR"}
      ],
      value <- [false, nil, ""] do
    @adapter adapter
    @variable variable
    @value value
    test "#{inspect(adapter)} rejects an unset home #{inspect(value)} before environment merge" do
      opts = [env: [{@variable, @value}]]
      assert_raise ArgumentError, ~r/nonempty home path/, fn -> @adapter.init(opts) end

      assert_raise ArgumentError, ~r/nonempty home path/, fn ->
        Arbor.ACP.AdapterSupport.Subprocess.safe_env(opts, @adapter)
      end
    end
  end

  test "explicit authentication refresh replaces only generated child credentials", %{root: root} do
    source = RuntimeHome.put_opt([], :claude)
    target = RuntimeHome.put_opt([_runtime_home_session: "child"], :claude)
    File.write!(Path.join(source[:claude_config_dir], ".credentials.json"), "account A")
    assert :ok = RuntimeHome.seed_auth(source, target, :claude)
    File.write!(Path.join(source[:claude_config_dir], ".credentials.json"), "account B")
    assert :ok = RuntimeHome.refresh_auth(source, target, :claude)
    assert File.read!(Path.join(target[:claude_config_dir], ".credentials.json")) == "account B"
    caller = [claude_config_dir: root]
    File.write!(Path.join(root, ".credentials.json"), "caller")
    assert :ok = RuntimeHome.refresh_auth(source, caller, :claude)
    assert File.read!(Path.join(root, ".credentials.json")) == "caller"

    assert Bitwise.band(
             File.stat!(Path.join(target[:claude_config_dir], ".credentials.json")).mode,
             0o777
           ) == 0o600

    RuntimeHome.release(source, :claude)
    RuntimeHome.release(target, :claude)
  end
end
