defmodule Arbor.ACP.Adapters.MixProject do
  use Mix.Project
  @version "2.0.0-rc.1"
  @internal_requirement "~> 2.0.0-rc.1"
  def project do
    [
      app: :arbor_acp_adapters,
      name: "ArborACP adapters",
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: paths(Mix.env()),
      deps: deps(),
      description: "Optional Claude, Codex, Pi and ZCode adapters for ArborACP.",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/trust-arbor/arbor_acp"},
        files: ~w(lib mix.exs .formatter.exs README.md LICENSE CHANGELOG.md)
      ],
      source_url: "https://github.com/trust-arbor/arbor_acp",
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"],
        source_ref: "arbor_acp_adapters-v#{@version}",
        source_url_pattern:
          "https://github.com/trust-arbor/arbor_acp/blob/arbor_acp_adapters-v#{@version}/packages/arbor_acp_adapters/%{path}#L%{line}"
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
  defp paths(:test), do: ["lib", "dev", "test/support"]
  defp paths(:dev), do: ["lib", "dev"]
  defp paths(_), do: ["lib"]

  defp deps do
    [
      internal_dep(:arbor_acp),
      internal_dep(:arbor_rpc),
      external_dep(:jason, "~> 1.4"),
      external_dep(:ex_doc, "~> 0.40", only: :dev, runtime: false),
      external_dep(:telemetry, "~> 1.2")
    ]
  end

  defp external_dep(app, version, opts \\ []) do
    case System.get_env("ARBOR_V2_DEPS") do
      nil ->
        {app, version, opts}

      directory ->
        {app, version,
         Keyword.merge(opts,
           path: Path.join(directory, to_string(app)),
           override: true
         )}
    end
  end

  defp internal_dep(app) do
    if System.get_env("ARBOR_V2_LOCAL") == "1",
      do: {app, path: Path.expand("../#{app}", __DIR__)},
      else: {app, @internal_requirement}
  end
end
