defmodule AgentExamples.Team do
  @moduledoc "Starts child agents and sends signals through the generated domain interface."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "example_team"

    schema do
      attribute :last_message, :string do
        description "The latest public message received by this coordinator."
      end

      attribute :last_requester, :term do
        description "Verified requesting member name, without storing a PID or execution scope."
      end
    end

    route AgentExamples.Team.Signals.Message, AgentExamples.Team.Actions.RecordMessage
  end

  team do
    member :counter, AgentExamples.Counter, initial_state: %{count: 10}
    member :notebook, AgentExamples.Notebook
    member :worker, AgentExamples.Worker
  end
end
