defmodule AgentExamples.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_examples,
      version: "0.1.0",
      elixir: "~> 1.19",
      consolidate_protocols: Mix.env() != :test,
      deps: [
        {:aikido, path: "../.."},
        {:ash, "~> 3.36"},
        {:phoenix, "~> 1.8"},
        {:phoenix_live_view, "~> 1.1"},
        {:phoenix_html, "~> 4.3"},
        {:bandit, "~> 1.6"},
        {:lazy_html, ">= 0.1.0", only: :test},
        {:ash_ai, "~> 1.3"},
        {:ash_lua,
         git: "https://github.com/ash-project/ash_lua.git",
         ref: "5388cbbcd176e3f879a713d948733d9f0e281cf6"},
        {:sourceror, "~> 1.7", only: [:dev, :test]}
      ],
      aliases: [
        demo: "run -e AgentExamples.Demo.run()",
        "spark.formatter": "spark.formatter --extensions AshAi,AshLua.Domain,AshLua.EvalActions",
        "ai.demo": "run -e AgentExamples.AI.Demo.run()",
        "ai.live": "run -e AgentExamples.AI.Demo.live()"
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :os_mon], mod: {AgentExamples.Application, []}]
  end
end
