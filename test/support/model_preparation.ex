defmodule Aikido.ModelPreparationTest.Prepare do
  @moduledoc "Application-native provider preparation observed through a real supervised model attempt."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, context) do
    send(
      context.actor.observer,
      {:model_preparing, self(), context.actor, context.tenant, input.context, input.arguments}
    )

    if input.context.aikido.metadata[:hold?] do
      receive do
        :release -> :ok
      end
    end

    {:ok,
     Aikido.AiReact.Types.ModelRequest.new!(
       model: "prepared:" <> input.context.aikido.metadata.profile,
       options:
         input.arguments.options
         |> Keyword.put(:api_key, "ephemeral-provider-secret-" <> Ash.UUIDv7.generate())
         |> Keyword.put(:observer, context.actor.observer)
     )}
  end
end

defmodule Aikido.ModelPreparationTest.InvalidResult do
  @moduledoc "Native action returning a credential-bearing malformed result to exercise the safe failure boundary."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _options, _context) do
    {:ok,
     %{model: "offline:invalid", options: [{:api_key, "private-invalid-return-secret", :invalid}]}}
  end
end

defmodule Aikido.ModelPreparationTest.Denied do
  @moduledoc "Native policy denial retaining no preparation input in the AI failure."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_options), do: "private-denied-preparation-secret"
  @impl true
  def match?(_actor, _context, _options), do: false
end

defmodule Aikido.ModelPreparationTest.Preparation do
  @moduledoc "Normal application Ash actions used by receiver-owned model preparation."
  use Ash.Resource,
    domain: Aikido.ModelPreparationTest.Domain,
    authorizers: [Ash.Policy.Authorizer]

  actions do
    action :prepare, Aikido.AiReact.Types.ModelRequest do
      argument :model, :term, allow_nil?: false

      argument :options, {:array, :tuple},
        allow_nil?: false,
        constraints: [items: [fields: [key: [type: :atom], value: [type: :term]]]]

      run Aikido.ModelPreparationTest.Prepare
    end

    action :invalid, :term do
      argument :model, :term, allow_nil?: false

      argument :options, {:array, :tuple},
        allow_nil?: false,
        constraints: [items: [fields: [key: [type: :atom], value: [type: :term]]]]

      run Aikido.ModelPreparationTest.InvalidResult
    end

    action :denied, Aikido.AiReact.Types.ModelRequest do
      argument :model, :term, allow_nil?: false

      argument :options, {:array, :tuple},
        allow_nil?: false,
        constraints: [items: [fields: [key: [type: :atom], value: [type: :term]]]]

      run Aikido.ModelPreparationTest.Prepare
    end
  end

  policies do
    policy action(:denied) do
      authorize_if Aikido.ModelPreparationTest.Denied
    end

    policy action([:prepare, :invalid]) do
      authorize_if actor_attribute_equals(:can_prepare?, true)
    end
  end
end

defmodule Aikido.ModelPreparationTest.Client do
  @moduledoc "Controlled provider callback; requests are real native AI runs without network transport."
  def generate_text(model, messages, options) do
    send(options[:observer], {:provider_called, self(), model, messages, options})

    receive do
      {:provider_result, result} -> result
    end
  end
end

defmodule Aikido.ModelPreparationTest.Worker do
  @moduledoc "An ordinary durable AI worker whose provider preparation uses its own activation scope."
  use Ash.Resource,
    domain: Aikido.ModelPreparationTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "model_preparation_worker"
    persistence :permanent

    schema do
      attribute :actor_id, :string do
        description "Actor authenticated by native durable restoration."
        allow_nil? false
      end

      attribute :metadata, :map do
        description "Application-owned provider selection metadata; contains no credentials."
        default %{}
      end
    end
  end

  ai do
    model "offline:original"
    client Aikido.ModelPreparationTest.Client

    options %{
      model_preparation: {Aikido.ModelPreparationTest.Preparation, :prepare},
      model_max_retries: 0
    }
  end
end

defmodule Aikido.ModelPreparationTest.WorkerConfigured do
  @moduledoc "A durable worker whose source declaration owns preparation independently of its saved AI options."
  use Ash.Resource,
    domain: Aikido.ModelPreparationTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "configured_model_preparation_worker"
    persistence :permanent

    schema do
      attribute :actor_id, :string do
        description "Actor authenticated by native durable restoration."
        allow_nil? false
      end

      attribute :metadata, :map do
        description "Application-owned provider selection metadata; contains no credentials."
        default %{}
      end
    end
  end

  ai do
    model "offline:original"
    client Aikido.ModelPreparationTest.Client

    model_preparation({Aikido.ModelPreparationTest.Preparation, :prepare})
    options %{model_max_retries: 0}
  end
end

defmodule Aikido.ModelPreparationTest.Team do
  @moduledoc "A real native coordinator used to prove delegated requests keep the worker's identity."
  use Ash.Resource,
    domain: Aikido.ModelPreparationTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "model_preparation_team"
    persistence :permanent

    schema do
      attribute :actor_id, :string do
        description "Coordinator identity, distinct from its existing receiving worker."
        allow_nil? false
      end
    end
  end

  team do
    worker :worker, Aikido.ModelPreparationTest.Worker
  end
end

defmodule Aikido.ModelPreparationTest.Domain do
  @moduledoc "Native public commands and preparation actions for model preparation integration tests."
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  resources do
    resource Aikido.ModelPreparationTest.Preparation
  end

  agents do
    agent :worker, Aikido.ModelPreparationTest.Worker
    agent :configured_worker, Aikido.ModelPreparationTest.WorkerConfigured
    agent :team, Aikido.ModelPreparationTest.Team
  end
end

defmodule Aikido.ModelPreparationTest.Authority do
  @moduledoc "Application-owned registry selecting pre-registered execution scopes before native credential issuance."
  use Agent
  @behaviour Aikido.Durable.ScopeAdapter

  def start_link(scopes) do
    Agent.start_link(fn -> Map.new(scopes, &{&1.actor.id, &1}) end, name: __MODULE__)
  end

  def register(scope), do: Agent.update(__MODULE__, &Map.put(&1, scope.actor.id, scope))

  @impl true
  def prepare(attributes, _caller_scope, identity) do
    actor_id = get_in(attributes, [:state, :actor_id])

    case Agent.get(__MODULE__, &Map.fetch(&1, actor_id)) do
      {:ok, scope} ->
        AikidoTest.DurableScopeAuthority.prepare(
          attributes,
          Ash.Scope.to_opts(scope, context: scope.context),
          identity
        )

      :error ->
        {:error, :unregistered_execution_scope}
    end
  end

  @impl true
  defdelegate restore(credential, saved, identity), to: AikidoTest.DurableScopeAuthority

  @impl true
  defdelegate checkpoint(agent, credential, identity), to: AikidoTest.DurableScopeAuthority
end
