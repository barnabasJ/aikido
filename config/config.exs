import Config

config :ash, default_string_length_count: :codepoints

config :spark, :formatter,
  remove_parens?: true,
  "Aikido.Agent": [type: Ash.Resource, extensions: [Aikido.Ash.Agent]],
  "Aikido.Slice": [type: Ash.Resource, extensions: [Aikido.Ash.Slice]],
  "Ash.Resource": [
    extensions: [Aikido.Ash.Agent, Aikido.Ash.Slice, Aikido.Ash.Team, Aikido.Ash.AI]
  ],
  "Ash.Domain": [extensions: [Aikido.Ash.Domain]],
  "Aikido.Directive": [],
  "Ash.TypedStruct": []

# Default scheduler time zone database
config :aikido, :time_zone_database, TimeZoneInfo.TimeZoneDatabase

# Logger configuration for Aikido telemetry metadata
# These metadata keys are used by Aikido.Telemetry for structured logging
config :logger, :default_formatter,
  format: "[$level] $message $metadata\n",
  metadata: [
    :agent_id,
    :agent_module,
    :action,
    :directive_count,
    :directive_type,
    :duration_μs,
    :error,
    :queue_size,
    :result,
    :signal_type,
    :span_id,
    :stacktrace,
    :trace_id
  ]

# Git hooks and git_ops configuration for conventional commits
# Only enabled in dev environment (git_ops is a dev-only dependency)
if config_env() == :dev do
  # Worktrees use a `.git` file instead of a directory. We keep the explicit
  # project path for git_hooks and only auto-install hooks from a normal checkout.
  project_path = Path.expand("..", __DIR__)
  auto_install_git_hooks? = File.dir?(Path.join(project_path, ".git"))

  config :git_hooks,
    auto_install: auto_install_git_hooks?,
    project_path: project_path,
    verbose: true,
    hooks: [
      commit_msg: [
        tasks: [
          {:cmd, "mix git_ops.check_message", include_hook_args: true}
        ]
      ]
    ]

  config :git_ops,
    mix_project: Aikido.MixProject,
    changelog_file: "CHANGELOG.md",
    repository_url: "https://github.com/barnabasJ/aikido",
    manage_mix_version?: true,
    manage_readme_version: "README.md",
    version_tag_prefix: "v",
    types: [
      feat: [header: "Features"],
      fix: [header: "Bug Fixes"],
      perf: [header: "Performance"],
      refactor: [header: "Refactoring"],
      docs: [hidden?: true],
      test: [hidden?: true],
      chore: [hidden?: true],
      ci: [hidden?: true]
    ]
end

# Import environment specific config (test.exs only)
if config_env() == :test do
  import_config "test.exs"
end
