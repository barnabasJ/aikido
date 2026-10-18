defmodule AgentExamples.Worker do
  @moduledoc "Action -> AsyncTask -> result signal -> action; no blocking agent calls."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Ash.Agent]

  agent do
    name "example_worker"

    schema do
      attribute :status, :atom,
        allow_nil?: false,
        default: :idle,
        constraints: [one_of: [:idle, :working, :completed, :failed]],
        public?: true

      attribute :result, :string, public?: true
      attribute :error, :term, public?: true
    end

    signal :run, "worker.run", AgentExamples.Actions.Work
    signal :completed, "worker.completed", AgentExamples.Actions.WorkResult
    signal :failed, "worker.failed", AgentExamples.Actions.WorkResult
  end
end
