defmodule Arbor.ACP.AdapterSupport.WorkspacePath do
  @moduledoc "Documented adapter support for WorkspacePath."

  @max_symlink_depth 40

  @type resolve_error :: :incomplete

  @spec within?(String.t(), String.t()) :: boolean()
  def within?(path, root) when is_binary(path) and is_binary(root) do
    case contained(path, root) do
      {:ok, _resolved} -> true
      :error -> false
    end
  end

  def within?(_path, _root), do: false

  @doc """
  Resolves `path` under `root` and returns the finished physical path.

  Returns `:error` when `path` is outside `root` or when symlink resolution
  cannot finish (the depth cap or a loop). Callers that will open or delete
  the path must use this result rather than resolving again.
  """
  @spec contained(String.t(), String.t()) :: {:ok, String.t()} | :error
  def contained(path, root) when is_binary(path) and is_binary(root) do
    with {:ok, resolved} <- resolve(path),
         {:ok, resolved_root} <- resolve(root),
         true <- contained_resolved?(resolved, resolved_root) do
      {:ok, resolved}
    else
      _ -> :error
    end
  end

  def contained(_path, _root), do: :error

  @doc """
  Deletes `path` when it resolves inside `root`.

  Containment is resolved once; the delete uses that path and does not
  resolve again. One process then walks from the resolved root: each
  ancestor is entered with `cd -P` only when an lstat of that component
  is a directory whose inode matches the directory landed in. The last
  component is unlinked relative to that cwd. A swap of the file or of
  an ancestor for a symlink is not followed.

  `opts[:after_contain]` runs after the containment check and before the
  ancestor walk, so tests can swap the path in the check-then-use window.

  `opts[:after_ancestors]` runs after the ancestor walk and before the
  anchored unlink, so tests can swap a grandparent in that window.
  """
  @spec rm_within(String.t(), String.t(), keyword()) :: :ok
  def rm_within(path, root, opts \\ []) when is_binary(path) and is_binary(root) do
    case contained(path, root) do
      {:ok, resolved} ->
        if hook = Keyword.get(opts, :after_contain), do: hook.()
        rm_contained(resolved, root, opts)

      :error ->
        :ok
    end
  end

  defp rm_contained(resolved, root, opts) do
    case resolve(root) do
      {:ok, resolved_root} ->
        if contained_resolved?(resolved, resolved_root) and
             directory_ancestors?(resolved, resolved_root) do
          if hook = Keyword.get(opts, :after_ancestors), do: hook.()
          anchored_unlink(resolved_root, resolved)
        else
          :ok
        end

      {:error, :incomplete} ->
        :ok
    end
  end

  defp directory_ancestors?(resolved, resolved_root) do
    relative = Path.relative_to(resolved, resolved_root)

    dirs =
      relative
      |> Path.split()
      |> Enum.drop(-1)
      |> Enum.scan(resolved_root, &Path.join(&2, &1))

    Enum.all?([resolved_root | dirs], fn dir ->
      match?({:ok, %File.Stat{type: :directory}}, File.lstat(dir))
    end)
  end

  defp anchored_unlink(resolved_root, resolved) do
    relative = Path.relative_to(resolved, resolved_root)

    case Path.split(relative) do
      [] ->
        :ok

      ["."] ->
        :ok

      components ->
        {dirs, [name]} = Enum.split(components, -1)

        with true <- Enum.all?([name | dirs], &safe_basename?/1),
             {:ok, root_info} <- File.lstat(resolved_root),
             :directory <- root_info.type do
          case :os.type() do
            {:unix, os} -> unix_anchored_unlink(resolved_root, root_info, dirs, name, os)
            _other -> File.rm(resolved)
          end
        else
          _ -> :ok
        end
    end
  end

  defp safe_basename?(name),
    do: name not in ["", ".", ".."] and not String.contains?(name, "/")

  defp unix_anchored_unlink(root, root_info, dirs, name, os) do
    {stat_flag, stat_fmt} =
      case os do
        :darwin -> {"-f", "%d:%i"}
        _ -> {"-c", "%d:%i"}
      end

    expected_root = "#{root_info.major_device}:#{root_info.inode}"

    script =
      "cd -P -- \"$1\" || exit 1\n" <>
        "actual=$(stat #{stat_flag} '#{stat_fmt}' .) || exit 1\n" <>
        "test \"$actual\" = \"$2\" || exit 2\n" <>
        "name=$3\n" <>
        "shift 3\n" <>
        "for comp do\n" <>
        "  case \"$comp\" in \"\"|\".\"|\"..\"|*/*) exit 3 ;; esac\n" <>
        "  [ -L \"$comp\" ] && exit 4\n" <>
        "  [ -d \"$comp\" ] || exit 5\n" <>
        "  expected=$(stat #{stat_flag} '#{stat_fmt}' \"$comp\") || exit 1\n" <>
        "  cd -P -- \"$comp\" || exit 1\n" <>
        "  actual=$(stat #{stat_flag} '#{stat_fmt}' .) || exit 1\n" <>
        "  test \"$actual\" = \"$expected\" || exit 2\n" <>
        "done\n" <>
        "case \"$name\" in \"\"|\".\"|\"..\"|*/*) exit 3 ;; esac\n" <>
        "exec rm -- \"$name\""

    case System.cmd("sh", ["-ec", script, "rm_within", root, expected_root, name | dirs],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      _other -> :ok
    end
  end

  # Walk the components left to right against the physically resolved prefix,
  # the way the kernel does, so `..` steps out of the directory a symlink
  # points at rather than cancelling the symlink component lexically.
  # Nonexistent final components retain their lexical location under the
  # resolved parent so safe create/write requests remain possible without
  # trusting symlink escapes.
  @spec canonical(String.t()) :: String.t()
  def canonical(path) when is_binary(path) do
    case resolve(path) do
      {:ok, resolved} -> resolved
      {:error, :incomplete} -> absolute(path)
    end
  end

  @doc """
  Resolves every symlink in `path`.

  Returns `{:error, :incomplete}` when a remaining symlink cannot be
  followed (the depth cap or a loop). Callers that authorize or mutate
  files must fail closed on that error instead of trusting a half-resolved
  path that still contains a link.
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, resolve_error()}
  def resolve(path) when is_binary(path), do: path |> absolute() |> resolve_ok(0)

  defp contained_resolved?(resolved, resolved_root) do
    relative = Path.relative_to(resolved, resolved_root)

    relative == "." or
      (Path.type(relative) == :relative and relative != ".." and
         not String.starts_with?(relative, "../"))
  end

  defp absolute("~"), do: System.user_home!()
  defp absolute("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp absolute(path), do: Path.absname(path)

  defp resolve_ok(path, depth) do
    case Path.split(path) do
      [base | components] -> resolve_components(components, base, depth)
      [] -> {:ok, path}
    end
  end

  defp resolve_components([], resolved, _depth), do: {:ok, resolved}

  defp resolve_components(["." | rest], resolved, depth),
    do: resolve_components(rest, resolved, depth)

  defp resolve_components([".." | rest], resolved, depth),
    do: resolve_components(rest, Path.dirname(resolved), depth)

  defp resolve_components([component | rest], resolved, depth) do
    candidate = Path.join(resolved, component)

    case :file.read_link(to_charlist(candidate)) do
      {:ok, _target} when depth >= @max_symlink_depth ->
        {:error, :incomplete}

      {:ok, target} ->
        target = to_string(target)
        target = if Path.type(target) == :absolute, do: target, else: Path.join(resolved, target)

        case resolve_ok(target, depth + 1) do
          {:ok, dest} -> resolve_components(rest, dest, depth + 1)
          {:error, _} = error -> error
        end

      _not_a_link ->
        resolve_components(rest, candidate, depth)
    end
  end
end
