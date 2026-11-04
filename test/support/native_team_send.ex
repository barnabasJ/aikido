defmodule AikidoTest.AshTeamActionsTest.Worker do
  @moduledoc "An ordinary worker hosted by the private native Send test runtime."
  use Ash.Resource,
    domain: AikidoTest.AshTeamActionsTest.Domain,
    extensions: [Aikido.Agent.Extension]

  agent do
    name "native_send_worker"
    instance AikidoTest.AshTeamActionsTest.Instance
    persistence :temporary
  end
end

defmodule AikidoTest.AshTeamActionsTest.Team do
  @moduledoc "A real topology providing current membership for native descriptor tests."
  use Ash.Resource,
    domain: AikidoTest.AshTeamActionsTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "native_send_team"
    instance AikidoTest.AshTeamActionsTest.Instance
    persistence :temporary
  end

  team do
    member :worker, AikidoTest.AshTeamActionsTest.Worker
  end
end

defmodule AikidoTest.AshTeamActionsTest.Domain do
  @moduledoc "Native lifecycle interfaces for the isolated Team Send descriptor scenario."
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  agents do
    agent :team, AikidoTest.AshTeamActionsTest.Team
    agent :worker, AikidoTest.AshTeamActionsTest.Worker
  end
end
