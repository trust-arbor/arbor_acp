defmodule Arbor.ACP.MixProject do
  use Mix.Project
  @version "2.0.0-rc.1"
  @internal_requirement "~> 2.0.0-rc.1"
  def project do
    [
      app: :arbor_acp,
      name: "ArborACP",
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: paths(Mix.env()),
      deps: deps(),
      description:
        "ArborACP: Agent Client Protocol client, native agent and generic adapter runtime.",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/trust-arbor/arbor_acp"},
        files: ~w(lib mix.exs .formatter.exs README.md LICENSE CHANGELOG.md)
      ],
      source_url: "https://github.com/trust-arbor/arbor_acp",
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"],
        source_ref: "arbor_acp-v#{@version}",
        source_url_pattern:
          "https://github.com/trust-arbor/arbor_acp/blob/arbor_acp-v#{@version}/packages/arbor_acp/%{path}#L%{line}"
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto, :inets, :ssl]]
  defp paths(:test), do: ["lib", "dev", "test/support"]
  defp paths(:dev), do: ["lib", "dev"]
  defp paths(_), do: ["lib"]

  defp deps do
    [
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

  defp internal_dep(:arbor_rpc) do
    case System.get_env("ARBOR_RPC_PATH") do
      nil -> {:arbor_rpc, @internal_requirement}
      path -> {:arbor_rpc, path: Path.expand(path)}
    end
  end
end
