defmodule ExACP.MixProject do
  use Mix.Project

  @version "0.1.0"
  @github_url "https://github.com/azmaveth/ex_acp"

  def project do
    [
      app: :ex_acp,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @github_url,
      homepage_url: @github_url,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl]]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Elixir implementation of the Agent Client Protocol (ACP). Control coding agents over stdio, with adapters for Claude Code, Codex, Pi, and ZCode, or build native ACP agents in Elixir.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @github_url,
        "Changelog" => "#{@github_url}/blob/master/CHANGELOG.md",
        "ACP Spec" => "https://agentclientprotocol.com"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  # dev/ holds repo-only tooling (ecosystem drift check, interop agents); it is
  # compiled for development and tests but is not in package.files.
  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      name: "ExACP",
      canonical: "https://hexdocs.pm/ex_acp",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        Client: [
          ExACP,
          ExACP.Client,
          ExACP.Client.Handler,
          ExACP.Client.DefaultHandler
        ],
        Agent: [
          ExACP.Agent,
          ExACP.Agent.Handler,
          ExACP.Agent.Transport,
          ExACP.Agent.Transport.Stdio,
          ExACP.Agent.Transport.Memory
        ],
        Protocol: [
          ExACP.Capabilities,
          ExACP.Protocol,
          ExACP.Types,
          ExACP.Registry
        ],
        Transports: [
          ExACP.Transport,
          ExACP.Transport.Stdio
        ],
        Adapters: [
          ExACP.Adapter,
          ExACP.AdapterEvents,
          ExACP.AdapterBridge,
          ExACP.AdapterTransport,
          ExACP.Adapters.ClaudeSDK,
          ExACP.Adapters.ClaudeSDK.SessionStore,
          ExACP.Adapters.Codex,
          ExACP.Adapters.Pi,
          ExACP.Adapters.ZCode
        ]
      ],
      filter_modules: fn mod, _ ->
        not String.starts_with?(inspect(mod), "ExACP.Internal.")
      end
    ]
  end
end
