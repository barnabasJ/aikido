defmodule AikidoJido.MixProject do
  use Mix.Project

  def project do
    [
      app: :aikido_jido,
      version: "0.0.1",
      elixir: "~> 1.19",
      deps: [
        {:ash, "~> 3.36"},
        {:sourceror, "~> 1.12", only: [:dev, :test], runtime: false},
        {:jido, github: "agentjido/jido", ref: "aaca071c90691662c7036fe4d71ab63e6ee3432a"}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
