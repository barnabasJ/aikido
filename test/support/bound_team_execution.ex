defmodule Aikido.BoundTeamExecutionTest.Instance do
  use Aikido, otp_app: :aikido
end

defmodule Aikido.BoundTeamExecutionTest.Authority do
  @behaviour Aikido.Durable.ScopeAdapter

  @impl true
  def prepare(attributes, options, identity) do
    actor_id = get_in(attributes, [:state, :actor_id])

    options =
      if actor_id,
        do: Keyword.put(options, :actor, %{id: actor_id, allowed: true}),
        else: options

    AikidoTest.DurableScopeAuthority.prepare(attributes, options, identity)
  end

  @impl true
  defdelegate restore(credential, saved, identity), to: AikidoTest.DurableScopeAuthority
  @impl true
  defdelegate checkpoint(agent, credential, identity), to: AikidoTest.DurableScopeAuthority
end

defmodule Aikido.BoundTeamExecutionTest.Prepare do
  use Ash.Resource, domain: Aikido.BoundTeamExecutionTest.Domain

  actions do
    action :prepare, :term do
      argument :options, :term
      argument :metadata, :map

      run fn input, context ->
        observer = get_in(context.source_context, [:shared, :observer])

        send(
          observer,
          {:preparing, context.actor.id, context.tenant, self(),
           context.source_context[:aikido_sender]}
        )

        if input.arguments.metadata[:hold] do
          receive do
            :release -> :ok
          end
        end

        {:ok, input.arguments.options}
      end
    end
  end
end

defmodule Aikido.BoundTeamExecutionTest.Client do
  def generate_text(_model, _messages, _options) do
    {:ok,
     %ReqLLM.Response{
       id: "bound-result",
       model: "offline",
       context: ReqLLM.Context.new(),
       message: ReqLLM.Context.assistant("done"),
       finish_reason: :stop
     }}
  end
end

defmodule Aikido.BoundTeamExecutionTest.OwnActor do
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_options), do: "the authenticated actor owns the current agent"

  @impl true
  def match?(%{id: id}, %{subject: %Ash.Changeset{data: %{actor_id: id}}}, _options),
    do: true

  def match?(_actor, _context, _options), do: false
end

defmodule Aikido.BoundTeamExecutionTest.Worker do
  use Ash.Resource,
    domain: Aikido.BoundTeamExecutionTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "bound_worker"
    instance Aikido.BoundTeamExecutionTest.Instance
    persistence :permanent

    schema do
      attribute :actor_id, :string do
        description "Execution identity authenticated by the test authority."
        allow_nil? false
      end
    end
  end

  ai do
    model "offline"
    client Aikido.BoundTeamExecutionTest.Client
    options %{tool_preparation: {Aikido.BoundTeamExecutionTest.Prepare, :prepare}}
  end

  policies do
    policy action_type(:update) do
      authorize_if Aikido.BoundTeamExecutionTest.OwnActor
    end

    policy action_type([:create, :action]) do
      authorize_if actor_attribute_equals(:allowed, true)
    end
  end
end

defmodule Aikido.BoundTeamExecutionTest.Team do
  use Ash.Resource,
    domain: Aikido.BoundTeamExecutionTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension, Aikido.AI.Extension]

  agent do
    name "bound_team"
    instance Aikido.BoundTeamExecutionTest.Instance
    persistence :permanent

    schema do
      attribute :actor_id, :string do
        description "Coordinator identity authenticated at activation."
        allow_nil? false
      end
    end
  end

  ai do
    model "offline"
    client Aikido.BoundTeamExecutionTest.Client

    options %{
      completion: :tasks,
      tool_preparation: {Aikido.BoundTeamExecutionTest.Prepare, :prepare}
    }
  end

  team do
    member :worker, Aikido.BoundTeamExecutionTest.Worker, initial_state: %{actor_id: "worker-B"}
  end

  policies do
    policy action_type(:update) do
      authorize_if Aikido.BoundTeamExecutionTest.OwnActor
    end

    policy action_type([:create, :action]) do
      authorize_if actor_attribute_equals(:allowed, true)
    end
  end
end

defmodule Aikido.BoundTeamExecutionTest.Unbound do
  use Ash.Resource,
    domain: Aikido.BoundTeamExecutionTest.Domain,
    extensions: [Aikido.Agent.Extension]

  agent do
    name "unbound"
    instance Aikido.BoundTeamExecutionTest.Instance
  end
end

defmodule Aikido.BoundTeamExecutionTest.Domain do
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  resources do
    resource Aikido.BoundTeamExecutionTest.Prepare
  end

  agents do
    agent :bound_team, Aikido.BoundTeamExecutionTest.Team
    agent :bound_worker, Aikido.BoundTeamExecutionTest.Worker
    agent :unbound, Aikido.BoundTeamExecutionTest.Unbound
  end
end
