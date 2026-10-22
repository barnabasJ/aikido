defmodule AgentExamples.ResilientAssistant.Failures do
  @moduledoc "An intentionally failing native Ash tool for testing model recovery limits."
  use Ash.Resource, domain: AgentExamples.Agents

  actions do
    action :fail, :map do
      run AgentExamples.ResilientAssistant.Actions.RejectWork
    end
  end
end
