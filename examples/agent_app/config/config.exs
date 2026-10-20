import Config

config :agent_examples, ash_domains: [AgentExamples.Agents]
config :ash, default_string_length_count: :codepoints

# Test VMs and the running playground must never open the same local EKV files.
# Set AIKIDO_DURABLE_DIR when running the server in MIX_ENV=test to retain state.
if config_env() == :test do
  directory =
    System.get_env("AIKIDO_DURABLE_DIR") ||
      Path.join(
        System.tmp_dir!(),
        "aikido-examples-#{System.pid()}-#{System.system_time(:microsecond)}"
      )

  config :aikido, :durable, data_dir: directory
end

config :spark, :formatter,
  remove_parens?: true,
  "Aikido.Agent": [type: Ash.Resource, extensions: [Aikido.Ash.Agent]],
  "Aikido.Slice": [type: Ash.Resource, extensions: [Aikido.Ash.Slice]],
  "Ash.Resource": [
    extensions: [Aikido.Ash.Agent, Aikido.Ash.Slice, Aikido.Ash.Team, Aikido.Ash.AI]
  ],
  "Ash.Domain": [extensions: [Aikido.Ash.Domain]],
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
