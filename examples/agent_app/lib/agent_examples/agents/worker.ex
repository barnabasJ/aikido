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

    signal :run, "worker.run", :work
    signal :completed, "worker.completed", :completed
    signal :failed, "worker.failed", :failed
  end

  actions do
    action :work, Aikido.Types.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :text, :string, allow_nil?: false
      run {AgentExamples.Worker.Implementation, action: :work}
    end

    action :completed, Aikido.Types.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :result, :string, allow_nil?: false
      run {AgentExamples.Worker.Implementation, action: :completed}
    end

    action :failed, Aikido.Types.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :reason, :term, allow_nil?: false
      run {AgentExamples.Worker.Implementation, action: :failed}
    end
  end

  def uppercase(text) do
    {:ok, String.upcase(text)}
  end
end
