import Config

config :agent_examples,
  ash_domains: [AgentExamples.Agents, AgentExamples.Settings],
  ecto_repos: [AgentExamples.Settings.Repo]

# Keep test VMs and the running playground on separate native EKV directories.
store_directory =
  System.get_env("AIKIDO_DURABLE_DIR") ||
    if config_env() == :test do
      Path.join(
        System.tmp_dir!(),
        "aikido-examples-#{System.pid()}-#{System.system_time(:microsecond)}"
      )
    else
      Path.expand("../_build/aikido_durable/Elixir.Aikido.Default.DurableAgents", __DIR__)
    end

# Reopening a native store with a different shard count changes key placement.
# Preserve existing stores; use eight shards for new high-concurrency playgrounds.
existing_shards = Path.wildcard(Path.join(store_directory, "shard_*.db")) |> length()
requested_shards = System.get_env("AIKIDO_EXAMPLES_EKV_SHARDS")

store_shards =
  if requested_shards,
    do: String.to_integer(requested_shards),
    else: if(existing_shards > 0, do: existing_shards, else: 8)

if existing_shards > 0 and store_shards != existing_shards do
  raise "The example store has #{existing_shards} EKV shards; reopening it with " <>
          "#{store_shards} would change key placement. Keep its shard count or choose " <>
          "a new AIKIDO_DURABLE_DIR. The existing store has not been modified."
end

config :agent_examples, :store,
  name: AgentExamples.Store,
  data_dir: store_directory,
  cluster_size: 1,
  node_id: "local",
  shards: store_shards,
  gc_interval: 30_000

config :aikido, :durable,
  scope_adapter: AgentExamples.DurableScope,
  backend: {DurableServer.Backends.EKVStore, name: AgentExamples.Store, timeout: 60_000}

config :ash, default_string_length_count: :codepoints
config :phoenix, :filter_parameters, ["api_key"]

config :spark, :formatter,
  remove_parens?: true,
  "Aikido.Agent": [type: Ash.Resource, extensions: [Aikido.Agent.Extension]],
  "Aikido.Slice": [type: Ash.Resource, extensions: [Aikido.Slice.Extension]],
  "Ash.Resource": [
    extensions: [
      Aikido.Agent.Extension,
      Aikido.Slice.Extension,
      Aikido.Team.Extension,
      Aikido.AI.Extension,
      AshSqlite.DataLayer,
      AshCloak
    ]
  ],
  "Ash.Domain": [extensions: [Aikido.Domain.Extension]],
  "Aikido.Directive": [],
  "Aikido.Signal": [type: Aikido.Signal.Definition, extensions: [Aikido.Signal.Dsl]],
  "Aikido.Signal.Definition": [],
  "Ash.TypedStruct": []

config :logger, level: :warning

config :agent_examples, AgentExamplesWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: String.duplicate("agent-examples-local-development-", 3),
  live_view: [signing_salt: "example-live-view"],
  pubsub_server: AgentExamples.PubSub,
  render_errors: [formats: [html: AgentExamplesWeb.ErrorHTML], layout: false]

settings_directory =
  if config_env() == :test do
    Path.join(
      System.tmp_dir!(),
      "aikido-settings-test-#{System.pid()}-#{System.unique_integer([:positive])}"
    )
  else
    System.get_env("AIKIDO_EXAMPLES_SETTINGS_DIR") || Path.expand("../.local", __DIR__)
  end

config :agent_examples, :settings_directory, settings_directory

config :agent_examples, AgentExamples.Settings.Repo,
  database: Path.join(settings_directory, "settings.sqlite3"),
  pool_size: 1,
  busy_timeout: 5_000,
  log: false
