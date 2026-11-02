defmodule AgentExamples.InteractiveAssistant.Approvals do
  @moduledoc "Application approval action exposed to the Lua hook VM."
  use Ash.Resource, domain: AgentExamples.Agents, authorizers: [Ash.Policy.Authorizer]

  policies do
    policy always() do
      forbid_unless actor_present()
      authorize_if AgentExamples.InteractiveAssistant.PlaygroundOwner
    end
  end

  actions do
    action :review, :map do
      description "Ask the current browser owner for fresh task approval."
      argument :title, :string, allow_nil?: false
      argument :details, :map
      argument :choices, {:array, :string}, allow_nil?: false
      run AgentExamples.InteractiveAssistant.Review
    end
  end
end
