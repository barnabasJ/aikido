defmodule AikidoTest.GeneratedAIBootstrap.Agent do
  use Ash.Resource,
    domain: AikidoTest.GeneratedAIBootstrap.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "generated_ai_bootstrap"
    instance AikidoTest.GeneratedAIBootstrap.Instance
  end

  ai do
    model "declared-model"

    hooks [
      %{
        name: "declared",
        event: :before_model,
        script: "return nil"
      }
    ]
  end
end

defmodule AikidoTest.GeneratedAIBootstrap.Domain do
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  resources do
    resource AikidoTest.GeneratedAIBootstrap.Agent
  end

  agents do
    agent :generated_ai, AikidoTest.GeneratedAIBootstrap.Agent
  end
end

defmodule AikidoTest.GeneratedAIBootstrap.CheckpointOnlyAgent do
  use Aikido.Agent, extensions: [Aikido.AI.Extension]

  agent do
    name "checkpoint_only_ai_bootstrap"
    instance AikidoTest.GeneratedAIBootstrap.Instance
  end

  @impl true
  def checkpoint(agent, _context), do: {:ok, %{id: agent.id}}

  @impl true
  def restore(checkpoint, _context), do: {:ok, initialize!(%{id: checkpoint.id})}
end
