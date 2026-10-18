defmodule Aikido.AgentServer.RuntimeActions do
  @moduledoc "Built-in native Ash actions available to every agent runtime."
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :query_children, Aikido.ActionResult do
      description "Reply with the agent's child process identifiers."
      run Aikido.AgentServer.Actions.QueryChildren
    end
  end
end
