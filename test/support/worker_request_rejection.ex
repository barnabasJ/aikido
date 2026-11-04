defmodule Aikido.WorkerRequestRejectionTest.Access do
  @moduledoc "Application-owned current model permission exercised by native Ask policies."
  use Ash.Resource,
    domain: Aikido.WorkerRequestRejectionTest.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    attribute :id, :string do
      description "Authenticated actor whose model access may be revoked."
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :active?, :boolean do
      description "Whether native AI request admission currently permits this actor."
      default true
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [:read, create: [:id, :active?], update: [:active?]]
  end
end

defmodule Aikido.WorkerRequestRejectionTest.ModelPermission do
  @moduledoc "Snapshots a real application grant and holds a denial for deterministic queued-task assertions."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_options), do: "private-worker-model-permission-secret"

  @impl true
  def match?(actor, _context, _options) do
    access = Ash.get!(Aikido.WorkerRequestRejectionTest.Access, actor.id, authorize?: false)

    unless access.active? do
      send(actor.observer, {:worker_ask_denied, self()})

      receive do
        :release_ask_denial -> :ok
      after
        5_000 -> raise "Native Ask denial was not released by its test"
      end
    end

    access.active?
  end
end

defmodule Aikido.WorkerRequestRejectionTest.Client do
  @moduledoc "Controlled provider callback for an actually admitted worker AI run."
  def generate_text(_model, messages, _options) do
    send(
      Process.whereis(Aikido.WorkerRequestRejectionTest.Observer),
      {:worker_provider, self(), messages}
    )

    receive do
      {:provider_result, result} -> result
    end
  end
end

defmodule Aikido.WorkerRequestRejectionTest.Worker do
  @moduledoc "A normal AI worker whose native Ask policy may deny an already accepted Team task."
  use Ash.Resource,
    domain: Aikido.WorkerRequestRejectionTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "request_rejection_worker"
    instance Aikido.WorkerRequestRejectionTest.Instance
    persistence :temporary

    schema do
      attribute :actor_id, :string do
        description "Application principal restored by the native scope adapter."
        allow_nil? false
      end
    end
  end

  ai do
    model "offline:request-rejection"
    client Aikido.WorkerRequestRejectionTest.Client
    options %{model_max_retries: 0}
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:allowed, true)
    end

    policy action(:ask) do
      authorize_if Aikido.WorkerRequestRejectionTest.ModelPermission
    end
  end
end

defmodule Aikido.WorkerRequestRejectionTest.Team do
  @moduledoc "An ordinary Team retaining the real delegated task ledger."
  use Ash.Resource,
    domain: Aikido.WorkerRequestRejectionTest.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "request_rejection_team"
    instance Aikido.WorkerRequestRejectionTest.Instance
    persistence :temporary

    schema do
      attribute :actor_id, :string do
        description "Coordinator principal, distinct from the receiving worker."
        allow_nil? false
      end
    end
  end
end

defmodule Aikido.WorkerRequestRejectionTest.Authority do
  @moduledoc "Application-owned registered immutable scopes for the native Team and worker."
  use Agent
  @behaviour Aikido.Durable.ScopeAdapter

  def start_link(scopes),
    do: Agent.start_link(fn -> Map.new(scopes, &{&1.actor.id, &1}) end, name: __MODULE__)

  @impl true
  def prepare(attributes, _options, identity) do
    id = get_in(attributes, [:state, :actor_id])

    case Agent.get(__MODULE__, &Map.fetch(&1, id)) do
      {:ok, scope} ->
        AikidoTest.DurableScopeAuthority.prepare(attributes, Ash.Scope.to_opts(scope), identity)

      :error ->
        {:error, :unknown_execution_identity}
    end
  end

  @impl true
  defdelegate restore(credential, saved, identity), to: AikidoTest.DurableScopeAuthority
  @impl true
  defdelegate checkpoint(agent, credential, identity), to: AikidoTest.DurableScopeAuthority
end

defmodule Aikido.WorkerRequestRejectionTest.Domain do
  @moduledoc "Native application interfaces for accepted-task request rejection scenarios."
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  resources do
    resource Aikido.WorkerRequestRejectionTest.Access
  end

  agents do
    agent :team, Aikido.WorkerRequestRejectionTest.Team
    agent :worker, Aikido.WorkerRequestRejectionTest.Worker
  end
end
