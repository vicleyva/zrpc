defmodule Zrpc.MixProject do
  use Mix.Project

  @version "0.0.0-alpha"
  @source_url "https://github.com/wavezync/zrpc"
  @homepage_url "https://zrpc.wavezync.com"

  def project do
    [
      app: :zrpc,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      aliases: aliases(),
      docs: docs(),
      name: "Zrpc",
      source_url: @source_url,
      homepage_url: @homepage_url
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Zrpc.Application, []}
    ]
  end

  defp description do
    "A modern RPC framework for Elixir. Define your API once, generate TypeScript clients and OpenAPI specs automatically."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Homepage" => @homepage_url
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE guides)
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      precommit: ["format", "compile --warnings-as-errors", "credo --strict", "test"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      homepage_url: @homepage_url,
      source_ref: "v#{@version}",
      formatters: ["html", "epub"],
      extras: [
        "README.md",
        "LICENSE",
        "guides/guide.md": [title: "Guide"]
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        Core: [
          Zrpc.Procedure,
          Zrpc.Router,
          Zrpc.Context,
          Zrpc.Middleware
        ],
        "Procedure Components": [
          Zrpc.Procedure.Definition,
          Zrpc.Procedure.Compiler,
          Zrpc.Procedure.Executor
        ],
        "Router Components": [
          Zrpc.Router.Entry,
          Zrpc.Router.Alias,
          Zrpc.Router.Compiler
        ]
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Core dependencies
      {:zoi, "~> 0.15"},
      {:telemetry, "~> 1.2"},
      {:jason, "~> 1.4"},

      # Dev/test dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
