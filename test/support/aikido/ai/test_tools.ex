defmodule Aikido.AI.TestTools.Wait.Actions.WaitForContinue do
  use Ash.Resource.Actions.Implementation

  def run(input, _, _) do
    send(input.context.observer, {:tool_running, self()})

    receive do
      :continue -> {:ok, "done"}
    end
  end
end

defmodule Aikido.AI.TestTools.Wait do
  use Ash.Resource,
    domain: Aikido.AI.TestToolDomain,
    data_layer: Ash.DataLayer.Simple,
    validate_domain_inclusion?: false

  actions do
    action :wait, :string do
      run Aikido.AI.TestTools.Wait.Actions.WaitForContinue
    end
  end
end

defmodule Aikido.AI.TestTools.Identity.Actions.ReportScope do
  use Ash.Resource.Actions.Implementation

  def run(input, _, context) do
    send(input.context.observer, {:tool_scope, context.actor.id, context.tenant})
    {:ok, "identity recorded"}
  end
end

defmodule Aikido.AI.TestTools.Identity do
  use Ash.Resource,
    domain: Aikido.AI.TestToolDomain,
    data_layer: Ash.DataLayer.Simple,
    validate_domain_inclusion?: false

  actions do
    action :identity, :string do
      run Aikido.AI.TestTools.Identity.Actions.ReportScope
    end
  end
end
