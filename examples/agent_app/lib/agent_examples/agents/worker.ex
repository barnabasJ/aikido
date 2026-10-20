defmodule AgentExamples.Worker do
  @moduledoc "Action -> AsyncTask -> result signal -> action; no blocking agent calls."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Ash.Agent]

  agent do
    name "example_worker"
    persistence :temporary

    schema do
      attribute :status, :atom,
        allow_nil?: false,
        default: :idle,
        constraints: [one_of: [:idle, :working, :completed, :failed]],
        public?: true

      attribute :result, :string, public?: true
      attribute :error, :term, public?: true
    end

    signal :run, AgentExamples.Worker.Signals.Run, AgentExamples.Worker.Work
    signal :completed, AgentExamples.Worker.Signals.Completed, AgentExamples.Worker.Completed
    signal :failed, AgentExamples.Worker.Signals.Failed, AgentExamples.Worker.Failed
  end

  def uppercase(text) do
    {:ok, String.upcase(text)}
  end
end
