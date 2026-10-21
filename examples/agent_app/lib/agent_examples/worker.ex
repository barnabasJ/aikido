defmodule AgentExamples.Worker do
  @moduledoc "Action -> AsyncTask -> result signal -> action; no blocking agent calls."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Ash.Agent]

  agent do
    name "example_worker"
    persistence :temporary

    schema do
      attribute :status, AgentExamples.Worker.Types.Status do
        description "Current stage of background work."
        allow_nil? false
        default :idle
        public? true
      end

      attribute :result, :string do
        description "Uppercase text returned by the background task."
        public? true
      end

      attribute :error, :term do
        description "Failure reason recorded when background work fails."
        public? true
      end
    end

    route AgentExamples.Worker.Signals.Run, AgentExamples.Worker.Actions.Work

    route AgentExamples.Worker.Signals.Completed, AgentExamples.Worker.Actions.Completed,
      public?: false

    route AgentExamples.Worker.Signals.Failed, AgentExamples.Worker.Actions.Failed, public?: false
  end

  def uppercase(text) do
    {:ok, String.upcase(text)}
  end
end
