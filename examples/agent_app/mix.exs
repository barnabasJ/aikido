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
        {:benchee, "~> 1.5", only: :dev, runtime: false},
        {:ash, "~> 3.37 and >= 3.37.2"},
        {:ash_sqlite, "~> 0.2.19"},
        {:ash_cloak, "~> 0.4"},
        {:cloak, "~> 1.1"},
        {:phoenix, "~> 1.8"},
        {:phoenix_live_view, "~> 1.1"},
        {:phoenix_live_dashboard, "~> 0.9.1"},
        {:telemetry_metrics, "~> 1.1"},
        {:telemetry_poller, "~> 1.1"},
        {:phoenix_html, "~> 4.3"},
        {:makeup_elixir, "~> 1.0"},
        {:makeup_json, "~> 1.0"},
        {:mdex, "~> 0.14.1"},
        {:bandit, "~> 1.6"},
        {:lazy_html, ">= 0.1.0", only: :test},
        {:ash_ai, "~> 1.3"},
        {:ash_lua,
         git: "https://github.com/barnabasJ/ash_lua.git",
         ref: "53fe11b883b7f8c8f6b85d07630bf78727a1efed"},
        {:sourceror, "~> 1.7", only: [:dev, :test]}
      ],
      aliases: [
        demo: "run -e AgentExamples.Demo.run()",
        "bench.quicksort": "run --no-start bench/quicksort.exs",
        "spark.formatter":
          "spark.formatter --extensions AshAi,AshLua.Domain,AshLua.EvalActions,AshSqlite.DataLayer,AshCloak",
        "ai.demo": "run -e AgentExamples.AI.Demo.run()",
        "ai.live": "run -e AgentExamples.AI.Demo.live()"
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :os_mon], mod: {AgentExamples.Application, []}]
  end
end
