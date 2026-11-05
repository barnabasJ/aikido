import Config

config :git_hooks, auto_install: false

# Keep Logger enabled but silent by default in tests.
# This allows ExUnit.CaptureLog to work while keeping test output clean.
#
# - :default_handler, false disables the default console handler
# - handle_otp_reports: false suppresses GenServer crash reports
# - handle_sasl_reports: false suppresses supervisor reports
#
# To enable verbose logging during debugging, set LOG_LEVEL env var:
#   LOG_LEVEL=debug mix test test/my_test.exs
#
log_level = System.get_env("LOG_LEVEL", "debug") |> String.to_existing_atom()

config :logger,
  level: log_level,
  handle_otp_reports: false,
  handle_sasl_reports: false

# Disable default console handler (OTP 21+ / Elixir 1.15+)
config :logger, :default_handler, false

config :aikido,
  ash_domains: [
    Aikido.AI.TestToolDomain,
    AikidoTest.AshFixtures.Domain,
    AikidoTest.StopScope.Domain,
    AikidoTest.TeamStopScope.Domain,
    AikidoTest.Atl47Native.Domain,
    AikidoTest.GeneratedAIBootstrap.Domain,
    AikidoTest.HookActions.Domain,
    Aikido.CommandRuntimeErrorTest.Domain,
    AikidoTest.LegacyCheckpoint.Domain,
    Aikido.InheritedConfigurationTest.Domain,
    Aikido.ThreadFollowTest.Domain,
    Aikido.ResolvedCommandAdmissionTest.Domain,
    AikidoTest.AgentServer.CallUntilCallersTest.Domain,
    Aikido.TeamMemberAdmissionTest.Domain,
    Aikido.ModelPreparationTest.Domain,
    Aikido.TeamMemberMessagingTest.Domain,
    AikidoTest.AshTeamActionsTest.Domain,
    Aikido.WorkerRequestRejectionTest.Domain,
    Aikido.RequesterCorrelationTest.Domain,
    Aikido.AncestorLossTest.Domain,
    Aikido.WorkerLaunchTest.Domain,
    Aikido.BoundTeamExecutionTest.Domain
  ]
