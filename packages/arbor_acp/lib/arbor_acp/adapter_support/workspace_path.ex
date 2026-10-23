defmodule Arbor.ACP.AdapterSupport.WorkspacePath do
  @moduledoc "Documented adapter support for WorkspacePath."

  @max_symlink_depth 40

  @spec within?(String.t(), String.t()) :: boolean()
  def within?(path, root) when is_binary(path) and is_binary(root) do
    relative = path |> canonical() |> Path.relative_to(canonical(root))

    relative == "." or
      (Path.type(relative) == :relative and relative != ".." and
         not String.starts_with?(relative, "../"))
  end

  def within?(_path, _root), do: false

  # Walk the components left to right against the physically resolved prefix,
  # the way the kernel does, so `..` steps out of the directory a symlink
  # points at rather than cancelling the symlink component lexically.
  # Nonexistent final components retain their lexical location under the
  # resolved parent so safe create/write requests remain possible without
  # trusting symlink escapes.
  @spec canonical(String.t()) :: String.t()
  def canonical(path) when is_binary(path), do: path |> absolute() |> resolve(0)

  defp absolute("~"), do: System.user_home!()
  defp absolute("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp absolute(path), do: Path.absname(path)

  defp resolve(path, depth) do
    case Path.split(path) do
      [base | components] -> resolve_components(components, base, depth)
      [] -> path
    end
  end

  defp resolve_components([], resolved, _depth), do: resolved

  defp resolve_components(["." | rest], resolved, depth),
    do: resolve_components(rest, resolved, depth)

  defp resolve_components([".." | rest], resolved, depth),
    do: resolve_components(rest, Path.dirname(resolved), depth)

  defp resolve_components([component | rest], resolved, depth) do
    candidate = Path.join(resolved, component)

    case :file.read_link(to_charlist(candidate)) do
      {:ok, target} when depth < @max_symlink_depth ->
        target = to_string(target)
        target = if Path.type(target) == :absolute, do: target, else: Path.join(resolved, target)
        resolve_components(rest, resolve(target, depth + 1), depth + 1)

      _not_a_link_or_too_deep ->
        resolve_components(rest, candidate, depth)
    end
  end
end
