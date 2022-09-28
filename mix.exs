defmodule ExUnit.ClusteredCase.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_unit_clustered_case,
      version: "0.5.0",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description: description(),
      elixirc_paths: elixirc_paths(Mix.env),
      preferred_cli_env: [
        docs: :docs,
        "hex.publish": :docs,
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :logger, :tools],
      mod: {ExUnit.ClusteredCase.App, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: [:docs], runtime: false}
    ]
  end

  defp description do
    "An extension for ExUnit for simplifying tests against a clustered application"
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["Paul Schoenfelder"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/bitwalker/ex_unit_clustered_case"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
