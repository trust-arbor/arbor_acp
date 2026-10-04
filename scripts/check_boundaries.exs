root = Path.expand("..", __DIR__)

violations =
  for package <- ~w(arbor_rpc arbor_acp arbor_acp_adapters),
      path <- Path.wildcard(Path.join(root, "packages/#{package}/lib/**/*.ex")),
      reduce: [] do
    errors ->
      ast = path |> File.read!() |> Code.string_to_quoted!()

      {_ast, references} =
        Macro.prewalk(ast, [], fn
          {:__aliases__, metadata, parts} = node, acc ->
            {node, [{Enum.map_join(parts, ".", &Atom.to_string/1), metadata[:line]} | acc]}

          node, acc ->
            {node, acc}
        end)

      Enum.reduce(references, errors, fn {module, line}, acc ->
        forbidden =
          cond do
            String.starts_with?(module, ["ExMCP", "ExACP"]) ->
              true

            package == "arbor_rpc" ->
              String.starts_with?(module, ["ArborACP", "ArborMCP"])

            package == "arbor_acp" ->
              String.starts_with?(module, "ArborACP.Adapters")

            package == "arbor_acp_adapters" ->
              String.starts_with?(module, "ArborACP.Internal") or
                module in ["ArborACP.Maps", "ArborACP.Envelope", "ArborACP.PendingRequests"]

            true ->
              false
          end

        if forbidden, do: ["#{Path.relative_to(path, root)}:#{line}: #{module}" | acc], else: acc
      end)
  end

if violations == [] do
  IO.puts("Package source boundaries pass")
else
  Enum.each(Enum.reverse(violations), &IO.puts/1)
  System.halt(1)
end
