defmodule AikidoTest.MultimodalUserTurn.Client do
  @moduledoc "A controlled external model boundary; the agent runtime remains real."
  @behaviour Aikido.AiReact.Client

  @impl true
  def generate_text(_model, messages, options) do
    send(options[:observer], {:multimodal_request, self(), messages})

    receive do
      {:answer, response} -> {:ok, response}
    after
      15_000 -> {:error, :provider_fixture_timeout}
    end
  end
end

defmodule AikidoTest.MultimodalUserTurn.Agent do
  use Ash.Resource,
    domain: AikidoTest.MultimodalUserTurn.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension],
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "multimodal_subject"
    instance AikidoTest.MultimodalUserTurn.Instance
    persistence :permanent
    slice :todos, Aikido.Todo.Slice
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end
end

defmodule AikidoTest.MultimodalUserTurn.Domain do
  use Ash.Domain, otp_app: :aikido, extensions: [Aikido.Domain.Extension]

  agents do
    agent :subject, AikidoTest.MultimodalUserTurn.Agent
  end
end
