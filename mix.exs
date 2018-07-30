defmodule ExUnit.ClusteredCase.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_unit_clustered_case,
      version: "0.1.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :logger],
      mod: {ExUnit.ClusteredCase.App, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.19", only: [:dev], runtime: false}
    ]
  end
end
