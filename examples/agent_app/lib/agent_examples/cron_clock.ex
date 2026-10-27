defmodule AgentExamples.CronClock do
  @moduledoc "Register and cancel a recurring signal; each tick re-enters an ordinary action."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Agent.Extension]

  agent do
    name "example_cron_clock"
    persistence :temporary

    schema do
      attribute :count, :integer do
        description "Number of scheduled ticks accepted while the clock is enabled."
        default 0
        allow_nil? false
        public? true
      end

      attribute :enabled, :boolean do
        description "Whether scheduled ticks should advance the counter."
        default false
        allow_nil? false
        public? true
      end
    end

    route AgentExamples.CronClock.Signals.Enable, AgentExamples.CronClock.Actions.Enable
    route AgentExamples.CronClock.Signals.Disable, AgentExamples.CronClock.Actions.Disable

    route AgentExamples.CronClock.Signals.Tick, AgentExamples.CronClock.Actions.CountTick,
      public?: false
  end
end
