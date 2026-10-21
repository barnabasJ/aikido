defmodule Aikido.MixProject do
  use Mix.Project

  @version "2.2.0"

  def vsn do
    @version
  end

  def project do
    [
      app: :aikido,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),

      # Docs
      name: "Aikido",
      description:
        "An autonomous agent framework for Elixir, built for workflows and multi-agent systems.",
      source_url: "https://github.com/barnabasJ/aikido",
      homepage_url: "https://github.com/barnabasJ/aikido",
      package: package(),
      docs: docs(),

      # Coverage
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 80],
        export: "cov",
        ignore_modules: [~r/^AikidoTest\./]
      ],

      # Dialyzer
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      argus: [
        ignore: [
          findings: [
            # DurableServer owns the process, traps exits and delegates termination.
            {:shutdown, {Aikido.AgentServer, :terminate, 2}},
            # Each durable identity has its own PID; this is not one shared server.
            {:blocking, {Aikido.AgentServer, :handle_call, 3}},
            # These finite names come from compiled Spark declarations, not runtime input.
            # Exact generated anchors fail closed if compiler output changes.
            {:unsafe_input,
             {Aikido.Agent.Extension.Transformers.Build, :"-resolve_local_actions/3-fun-1-", 3}},
            {:unsafe_input,
             {Aikido.Domain.Extension.Transformers.Build, :"-register/2-fun-1-", 2}},
            # Reads our trusted, compressed backend snapshots, including native callbacks.
            {:unsafe_input, {Aikido.Durable.AgentServer, :load_state, 2}},
            # Task-capacity fallback kills only the already retired scheduler PID.
            {:failure, {Aikido.Cron.Directives.Cancel, :shutdown_io, 3}},
            # Flushes only a queued worker EXIT after unlink, with a zero timeout.
            {:blocking, {Aikido.Cron.Job, :handle_info, 2}}
          ]
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :os_mon],
      mod: {Aikido.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        bench: :dev,
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.lcov": :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.cobertura": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      api_reference: false,
      source_ref: "v#{@version}",
      source_url: "https://github.com/barnabasJ/aikido",
      authors: ["barnabasJ", "Jido contributors"],
      groups_for_extras: [
        "Current Guides": [
          "guides/ash-integration.md",
          "guides/teams.md",
          "guides/runtime-patterns.md",
          "guides/multi-tenancy.md"
        ],
        Examples: ["examples/agent_app/README.md", "examples/agent_app/AI.md"],
        Project: ["CONTRIBUTING.md", "CHANGELOG.md", "LICENSE"]
      ],
      extras: [
        {"README.md", title: "Home"},
        {"guides/ash-integration.md", title: "Ash Integration"},
        {"guides/teams.md", title: "Teams"},
        {"guides/runtime-patterns.md", title: "Runtime Patterns"},
        {"guides/multi-tenancy.md", title: "Multi-Tenancy"},
        {"examples/agent_app/README.md", title: "Example Application", filename: "example-app"},
        {"examples/agent_app/AI.md", title: "AI Examples", filename: "ai-examples"},
        {"CONTRIBUTING.md", title: "Contributing"},
        {"CHANGELOG.md", title: "Changelog"},
        {"LICENSE", title: "Apache 2.0 License"}
      ],
      extra_section: "Guides",
      formatters: ["html"],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md", "LICENSE"],
      groups_for_modules: [
        "Resource Extensions": [~r/^Aikido\.(?:Agent|Slice|Domain)\.Extension(?:\.|$)/],
        Durability: [~r/^Aikido\.Durable(?:\.|$)/],
        "Actions and Effects": [~r/^Aikido\.(?:Actions|Directives)(?:\.|$)/],
        Features: [
          ~r/^Aikido\.(?:Cron|FSM|AiReact|AiWorker|AI|Identity|Memory|Thread|Todo|Team)(?:\.|$)/
        ],
        Runtime: [Aikido, Aikido.Agent, Aikido.AgentServer, ~r/^Aikido\.AgentServer\./],
        "Types and DSL": [~r/^Aikido\.(?:Types|Dsl)(?:\.|$)/],
        Observability: [~r/^Aikido\.(?:Observe|Debug|Telemetry|Tracing)(?:\.|$)/]
      ]
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE", "NOTICE", "usage-rules.md"],
      maintainers: ["barnabasJ"],
      licenses: ["Apache-2.0"],
      links: %{
        "Documentation" => "https://github.com/barnabasJ/aikido/blob/main/README.md",
        "GitHub" => "https://github.com/barnabasJ/aikido",
        "Changelog" => "https://github.com/barnabasJ/aikido/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp deps do
    [
      {:durable_server, "~> 0.1.6"},
      {:ekv, "~> 0.4"},
      # Aikido Deps
      {:ash, "~> 3.36"},
      {:ash_ai, "~> 1.3"},
      {:lua, "~> 1.0.2"},
      {:ash_lua,
       git: "https://github.com/ash-project/ash_lua.git",
       ref: "5388cbbcd176e3f879a713d948733d9f0e281cf6"},
      {:simple_sat, "~> 0.1"},
      {:deep_merge, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:phoenix_pubsub, "~> 2.1"},
      {:req_llm, "~> 1.24"},
      {:spark, "~> 2.2"},
      {:splode, "~> 0.3.0"},
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.1"},
      {:crontab, "~> 1.2"},
      {:time_zone_info, "~> 0.7"},

      # Development & Test Dependencies
      {:benchee, "~> 1.5", only: :dev, runtime: false},
      {:sourceror, "~> 1.12", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:argus_beam, "~> 0.24.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.21", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18.3", only: [:dev, :test]},
      {:expublish, "~> 2.7", only: [:dev], runtime: false},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
      {:mimic, "~> 2.0", only: :test},
      {:stream_data, "~> 1.0"},
      {:mix_test_interactive, "~> 5.1", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    dsl_extensions =
      Enum.join(
        ~w(Aikido.Instance.Dsl Aikido.Agent.Extension Aikido.Slice.Extension
           Aikido.Team.Extension Aikido.AI.Extension Aikido.Domain.Extension
           Ash.TypedStruct.Dsl Aikido.Signal.Dsl),
        ","
      )

    [
      bench: ["run bench/run.exs"],

      # Helper to run docs
      docs: "docs -f html --open",

      # Regenerate current DSL references and formatter declarations
      "spark.formatter": "spark.formatter --extensions #{dsl_extensions}",
      "spark.docs": [
        "spark.cheat_sheets --extensions #{dsl_extensions}",
        "spark.formatter"
      ],

      # Run to check the quality of your code
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority high",
        "argus --all --fail-above 0",
        "dialyzer"
      ]
    ]
  end
end
