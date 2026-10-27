defmodule AgentExamples.CheckpointCounter do
  @moduledoc "Permanent counter demonstrating the difference between live and checkpointed state."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Agent.Extension]

  agent do
    name "example_checkpoint_counter"
    persistence :permanent

    schema do
      attribute :count, :integer do
        description "Live counter restored from the most recent durable checkpoint."
        default 0
        allow_nil? false
        public? true
      end
    end

    route AgentExamples.CheckpointCounter.Signals.Add, AgentExamples.Counter.Actions.Increment

    route AgentExamples.CheckpointCounter.Signals.Crash,
          AgentExamples.CheckpointCounter.Actions.Crash
  end
end
