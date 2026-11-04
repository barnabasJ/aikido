defmodule Aikido.AncestorLossTest.Worker do
  @moduledoc "An ordinary owned worker for deterministic ancestor-loss recovery."
  use Ash.Resource,
    domain: Aikido.AncestorLossTest.Domain,
    extensions: [Aikido.Agent.Extension]

  agent do
    name "ancestor_loss_worker"
    instance Aikido.AncestorLossTest.Instance
    persistence :temporary
  end
end

defmodule Aikido.AncestorLossTest.Team do
  @moduledoc "A real topology whose descendants follow their native parent-death policy."
  use Ash.Resource,
    domain: Aikido.AncestorLossTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "ancestor_loss_team"
    instance Aikido.AncestorLossTest.Instance
    persistence :temporary
  end

  team do
    worker :worker, Aikido.AncestorLossTest.Worker
  end
end

defmodule Aikido.AncestorLossTest.Domain do
  @moduledoc "Native lifecycle commands for isolated ownership-ancestor recovery."
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  agents do
    agent :team, Aikido.AncestorLossTest.Team
    agent :worker, Aikido.AncestorLossTest.Worker
  end
end
