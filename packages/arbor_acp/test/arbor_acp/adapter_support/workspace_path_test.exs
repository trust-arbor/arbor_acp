defmodule Arbor.ACP.AdapterSupport.WorkspacePathTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arbor.ACP.AdapterSupport.WorkspacePath

  setup do
    base =
      Path.join(System.tmp_dir!(), "workspace_path_test_#{System.unique_integer([:positive])}")

    root = Path.join(base, "ws")
    outside = Path.join(base, "outside")
    File.mkdir_p!(Path.join(root, "src"))
    File.mkdir_p!(outside)
    File.write!(Path.join(base, "secret.txt"), "secret")
    File.write!(Path.join(outside, "secret.txt"), "secret")
    File.write!(Path.join(root, "src/main.ex"), "ok")
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, root: root, outside: outside}
  end

  test "plain paths under the root are within it", %{root: root} do
    assert WorkspacePath.within?(root, root)
    assert WorkspacePath.within?(Path.join(root, "src/main.ex"), root)
    assert WorkspacePath.within?(Path.join(root, "src/./main.ex"), root)
    assert WorkspacePath.within?(Path.join(root, "src/../src/main.ex"), root)
    assert WorkspacePath.within?(Path.join(root, "new/file.txt"), root)
  end

  test "lexical escapes are rejected", %{root: root, base: base} do
    refute WorkspacePath.within?(Path.join(root, "../secret.txt"), root)
    refute WorkspacePath.within?(Path.join(root, "src/../../secret.txt"), root)
    refute WorkspacePath.within?(Path.join(base, "secret.txt"), root)
    refute WorkspacePath.within?(root <> "-sibling/file", root)
  end

  test "a symlink that leaves the root is rejected", %{root: root, outside: outside} do
    File.ln_s!(outside, Path.join(root, "link"))
    refute WorkspacePath.within?(Path.join(root, "link/secret.txt"), root)
  end

  test "`..` after a symlink is applied to the link target, not the link",
       %{root: root, outside: outside, base: base} do
    File.ln_s!(outside, Path.join(root, "link"))
    escaped = Path.join(root, "link/../secret.txt")

    assert WorkspacePath.canonical(escaped) ==
             WorkspacePath.canonical(Path.join(base, "secret.txt"))

    refute WorkspacePath.within?(escaped, root)
    refute WorkspacePath.within?(Path.join(root, "src/../link/../secret.txt"), root)
  end

  test "relative symlink targets with `..` are resolved physically", %{root: root, base: base} do
    File.ln_s!("../outside", Path.join(root, "rel"))
    escaped = Path.join(root, "rel/../secret.txt")

    assert WorkspacePath.canonical(escaped) ==
             WorkspacePath.canonical(Path.join(base, "secret.txt"))

    refute WorkspacePath.within?(escaped, root)
  end

  test "symlinks that stay inside the root are allowed", %{root: root} do
    File.ln_s!(Path.join(root, "src"), Path.join(root, "alias"))
    assert WorkspacePath.within?(Path.join(root, "alias/main.ex"), root)
    assert WorkspacePath.within?(Path.join(root, "alias/../src/main.ex"), root)
  end

  test "nonexistent components keep their lexical location", %{root: root} do
    assert WorkspacePath.canonical(Path.join(root, "missing/../src/main.ex")) ==
             WorkspacePath.canonical(Path.join(root, "src/main.ex"))

    assert WorkspacePath.within?(Path.join(root, "missing/new.ex"), root)
  end

  test "`..` cannot climb above the filesystem root" do
    assert WorkspacePath.canonical("/../../etc") == WorkspacePath.canonical("/etc")
  end

  test "symlink loops terminate", %{root: root} do
    File.ln_s!(Path.join(root, "loop_b"), Path.join(root, "loop_a"))
    File.ln_s!(Path.join(root, "loop_a"), Path.join(root, "loop_b"))
    looped = Path.join(root, "loop_a/file")
    assert is_binary(WorkspacePath.canonical(looped))
    assert {:error, :incomplete} = WorkspacePath.resolve(looped)
    refute WorkspacePath.within?(looped, root)
  end

  test "a 41-symlink chain that leaves the root is rejected", %{root: root, outside: outside} do
    last = Path.join(root, "link41")
    File.ln_s!(outside, last)

    Enum.each(40..1//-1, fn n ->
      File.ln_s!(Path.join(root, "link#{n + 1}"), Path.join(root, "link#{n}"))
    end)

    escaped = Path.join(root, "link1/secret.txt")
    assert {:error, :incomplete} = WorkspacePath.resolve(escaped)
    refute WorkspacePath.within?(escaped, root)
    assert WorkspacePath.contained(escaped, root) == :error
  end

  test "rm_within deletes a regular file inside the root", %{root: root} do
    inside = Path.join(root, "inside.txt")
    File.write!(inside, "session")
    assert :ok = WorkspacePath.rm_within(inside, root)
    refute File.exists?(inside)
  end

  test "rm_within deletes a nested regular file inside the root", %{root: root} do
    parent = Path.join(root, "grand/parent")
    File.mkdir_p!(parent)
    inside = Path.join(parent, "inside.txt")
    File.write!(inside, "session")
    assert :ok = WorkspacePath.rm_within(inside, root)
    refute File.exists?(inside)
  end

  test "rm_within does not delete an outside file swapped in after containment",
       %{root: root, outside: outside} do
    inside = Path.join(root, "inside.txt")
    secret = Path.join(outside, "secret.txt")
    File.write!(inside, "session")
    File.write!(secret, "secret")

    :ok =
      WorkspacePath.rm_within(inside, root,
        after_contain: fn ->
          File.rm!(inside)
          File.ln_s!(secret, inside)
        end
      )

    assert File.exists?(secret)
  end

  test "rm_within does not follow a parent swapped for a symlink after containment",
       %{root: root, outside: outside} do
    sub = Path.join(root, "sub")
    File.mkdir_p!(sub)
    inside = Path.join(sub, "secret.txt")
    secret = Path.join(outside, "secret.txt")
    File.write!(inside, "session")
    File.write!(secret, "secret")

    :ok =
      WorkspacePath.rm_within(inside, root,
        after_contain: fn ->
          File.rm!(inside)
          File.rmdir!(sub)
          File.ln_s!(outside, sub)
        end
      )

    assert File.exists?(secret)
  end

  test "rm_within does not follow a grandparent swapped after the ancestor walk",
       %{root: root, outside: outside} do
    grand = Path.join(root, "grand")
    parent = Path.join(grand, "parent")
    File.mkdir_p!(parent)
    File.mkdir_p!(Path.join(outside, "parent"))
    inside = Path.join(parent, "secret.txt")
    secret = Path.join(outside, "parent/secret.txt")
    File.write!(inside, "session")
    File.write!(secret, "secret")

    :ok =
      WorkspacePath.rm_within(inside, root,
        after_ancestors: fn ->
          File.rm_rf!(grand)
          File.ln_s!(outside, grand)
        end
      )

    assert File.exists?(secret)
  end

  test "rm_within does not follow an ancestor above its root swapped after validation", %{
    root: root,
    outside: outside
  } do
    container = Path.join(root, "container")
    sessions = Path.join(container, "sessions")
    File.mkdir_p!(sessions)
    outside_sessions = Path.join(outside, "sessions")
    File.mkdir_p!(outside_sessions)
    inside = Path.join(sessions, "secret.txt")
    secret = Path.join(outside_sessions, "secret.txt")
    File.write!(inside, "session")
    File.write!(secret, "caller data")

    assert :ok =
             WorkspacePath.rm_within(inside, sessions,
               after_ancestors: fn ->
                 File.rename!(container, container <> ".saved")
                 File.ln_s!(outside, container)
               end
             )

    assert File.read!(secret) == "caller data"
  end

  test "rm_within keeps the original root identity across directory replacement", %{
    root: root,
    outside: outside
  } do
    sessions = Path.join(root, "sessions")
    File.mkdir_p!(sessions)
    File.write!(Path.join(sessions, "session.txt"), "original")
    File.write!(Path.join(outside, "session.txt"), "replacement")

    assert :ok =
             WorkspacePath.rm_within(Path.join(sessions, "session.txt"), sessions,
               after_ancestors: fn ->
                 File.rename!(sessions, sessions <> ".saved")
                 File.rename!(outside, sessions)
               end
             )

    assert File.read!(Path.join(sessions, "session.txt")) == "replacement"
    assert File.read!(Path.join(sessions <> ".saved", "session.txt")) == "original"
  end

  test "rm_within unlinks a final symlink without deleting its contained target", %{root: root} do
    target = Path.join(root, "target.txt")
    link = Path.join(root, "link.txt")
    File.write!(target, "keep")
    File.ln_s!(target, link)
    assert :ok = WorkspacePath.rm_within(link, root)
    assert File.read!(target) == "keep"
    assert {:error, :enoent} = File.lstat(link)
  end

  test "rm_within fails closed for a NUL in the final filename", %{root: root} do
    assert :ok = WorkspacePath.rm_within(Path.join(root, "bad" <> <<0>> <> "name"), root)
    assert File.read!(Path.join(root, "src/main.ex")) == "ok"
  end

  test "rm_within fails closed for a NUL in a parent component", %{root: root} do
    assert :ok = WorkspacePath.rm_within(Path.join(root, "bad" <> <<0>> <> "/name"), root)
    assert File.read!(Path.join(root, "src/main.ex")) == "ok"
  end

  test "rm_within warns and emits telemetry when a delete is refused as outside the root",
       %{root: root, outside: outside} do
    secret = Path.join(outside, "secret.txt")
    File.write!(secret, "secret-token-value")
    parent = self()
    handler_id = "rm-within-outside-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:arbor_acp, :workspace_path, :rm_within, :failed],
      fn event, measurements, metadata, _config ->
        send(parent, {:rm_failed, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        assert :ok = WorkspacePath.rm_within(secret, root)
      end)

    assert File.read!(secret) == "secret-token-value"
    assert log =~ "workspace delete refused"
    assert log =~ "outside"
    refute log =~ "secret-token-value"
    refute log =~ secret

    assert_receive {:rm_failed, [:arbor_acp, :workspace_path, :rm_within, :failed], %{count: 1},
                    metadata}

    assert metadata.reason == :outside
    assert metadata.path == "[outside]"
    refute to_string(metadata.path) =~ "secret"
  end

  test "rm_within warns when an in-root unlink fails", %{root: root} do
    parent = Path.join(root, "locked")
    File.mkdir_p!(parent)
    inside = Path.join(parent, "file.txt")
    File.write!(inside, "keep")
    File.chmod!(parent, 0o555)

    on_exit(fn ->
      File.chmod!(parent, 0o755)
    end)

    parent_pid = self()
    handler_id = "rm-within-unlink-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:arbor_acp, :workspace_path, :rm_within, :failed],
      fn event, measurements, metadata, _config ->
        send(parent_pid, {:rm_failed, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        assert :ok = WorkspacePath.rm_within(inside, root)
      end)

    assert File.read!(inside) == "keep"
    assert log =~ "workspace delete refused"
    assert log =~ "unlink_failed"
    assert log =~ "locked/file.txt"
    refute log =~ root

    assert_receive {:rm_failed, [:arbor_acp, :workspace_path, :rm_within, :failed], %{count: 1},
                    metadata}

    assert metadata.reason == :unlink_failed
    assert metadata.path == "locked/file.txt"
  end

  test "rm_within treats a missing in-root file as success", %{root: root} do
    missing = Path.join(root, "gone.txt")
    refute File.exists?(missing)
    parent = self()
    handler_id = "rm-within-missing-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:arbor_acp, :workspace_path, :rm_within, :failed],
      fn event, measurements, metadata, _config ->
        send(parent, {:rm_failed, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        assert :ok = WorkspacePath.rm_within(missing, root)
      end)

    refute log =~ "workspace delete refused"
    refute_received {:rm_failed, _, _, _}
  end

  test "rm_within refuses an in-root path that escapes through a symlink",
       %{root: root, outside: outside} do
    File.ln_s!(outside, Path.join(root, "link"))
    secret = Path.join(outside, "secret.txt")
    File.write!(secret, "secret-token-value")
    escaped = Path.join(root, "link/secret.txt")
    parent = self()
    handler_id = "rm-within-symlink-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:arbor_acp, :workspace_path, :rm_within, :failed],
      fn event, measurements, metadata, _config ->
        send(parent, {:rm_failed, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        assert :ok = WorkspacePath.rm_within(escaped, root)
      end)

    assert File.read!(secret) == "secret-token-value"
    assert log =~ "workspace delete refused"
    assert log =~ "outside"
    refute log =~ "secret-token-value"
    refute log =~ secret

    assert_receive {:rm_failed, [:arbor_acp, :workspace_path, :rm_within, :failed], %{count: 1},
                    metadata}

    assert metadata.reason == :outside
    assert metadata.path == "link/secret.txt"
  end

  test "rm_within replaces control characters in the logged path", %{root: root} do
    parent = Path.join(root, "locked")
    File.mkdir_p!(parent)
    inside = Path.join(parent, "file\n\t.txt")
    File.write!(inside, "keep")
    File.chmod!(parent, 0o555)

    on_exit(fn ->
      File.chmod!(parent, 0o755)
    end)

    parent_pid = self()
    handler_id = "rm-within-control-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:arbor_acp, :workspace_path, :rm_within, :failed],
      fn event, measurements, metadata, _config ->
        send(parent_pid, {:rm_failed, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        assert :ok = WorkspacePath.rm_within(inside, root)
      end)

    assert File.read!(inside) == "keep"
    refute log =~ "file\n\t.txt"

    assert_receive {:rm_failed, [:arbor_acp, :workspace_path, :rm_within, :failed], %{count: 1},
                    metadata}

    assert metadata.reason == :unlink_failed
    assert metadata.path == "locked/file??.txt"
    refute metadata.path =~ "\n"
    refute metadata.path =~ "\t"
  end
end
