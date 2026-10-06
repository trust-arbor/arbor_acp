root = Path.expand("..", __DIR__)

packages = ~w(arbor_acp arbor_acp_adapters)

for package <- packages do
  source = Path.join(root, "packages/#{package}/lib")
  unless File.dir?(source), do: raise("Missing package source: #{source}")
end

violations =
  for package <- packages,
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

            package == "arbor_acp" ->
              String.starts_with?(module, "Arbor.ACP.Adapters")

            package == "arbor_acp_adapters" ->
              String.starts_with?(module, "Arbor.ACP.Internal") or
                module in ["Arbor.ACP.Maps", "Arbor.ACP.Envelope", "Arbor.ACP.PendingRequests"]

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
