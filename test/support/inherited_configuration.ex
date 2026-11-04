defmodule Aikido.InheritedConfigurationTest.Access do
  @moduledoc "Application permissions consulted by real agent policies on every inherited update."
  use Ash.Resource,
    domain: Aikido.InheritedConfigurationTest.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    attribute :id, :string do
      description "Application principal identity."
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :active?, :boolean do
      description "Current application permission, independent of the saved activation scope."
      default true
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [:read, create: [:id, :active?], update: [:active?]]
  end
end

defmodule Aikido.InheritedConfigurationTest.ActiveActor do
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_options),
    do: "the actual execution principal still has current application permission"

  @impl true
  def match?(%{id: id}, _context, _options) do
    case Ash.get(Aikido.InheritedConfigurationTest.Access, id, authorize?: false) do
      {:ok, %{active?: true}} -> true
      _ -> false
    end
  end

  def match?(_actor, _context, _options), do: false
end

defmodule Aikido.InheritedConfigurationTest.OwnExecutionActor do
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_options), do: "the actual receiving principal owns this agent"

  @impl true
  def match?(%{id: id}, %{subject: %Ash.Changeset{data: %{actor_id: id}}}, _options), do: true

  def match?(
        %{id: id},
        %{subject: %Ash.ActionInput{context: %{aikido: %{agent: agent}}}},
        _options
      ),
      do: Aikido.Agent.resource_attributes(agent).actor_id == id

  def match?(_actor, _context, _options), do: false
end

defmodule Aikido.InheritedConfigurationTest.Authority do
  @behaviour Aikido.Durable.ScopeAdapter

  @impl true
  def prepare(attributes, options, identity) do
    actor_id = get_in(attributes, [:state, :actor_id])

    options =
      if actor_id, do: Keyword.put(options, :actor, %{id: actor_id, allowed: true}), else: options

    AikidoTest.DurableScopeAuthority.prepare(attributes, options, identity)
  end

  @impl true
  defdelegate restore(credential, saved, identity), to: AikidoTest.DurableScopeAuthority

  @impl true
  defdelegate checkpoint(agent, credential, identity), to: AikidoTest.DurableScopeAuthority
end

defmodule Aikido.InheritedConfigurationTest.SetStorage do
  use Aikido.Signal

  signal do
    type "test.storage.configure"

    schema do
      attribute :storage_id, :term do
        description "Application-selected destination; child resources apply their own narrower native types."
        allow_nil? false
      end

      attribute :storage_replay?, :boolean do
        description "Whether retained replay is wanted."
        default false
        allow_nil? false
      end
    end
  end
end

defmodule Aikido.InheritedConfigurationTest.ConfigureStorage do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, _context) do
    Aikido.Types.ActionResult.new(
      changes: Map.take(input.arguments, [:storage_id, :storage_replay?])
    )
  end
end

defmodule Aikido.InheritedConfigurationTest.StorageFields do
  @moduledoc "Shared native declarations for this application's real storage-aware agents."
  defmacro __using__(options) do
    storage_type = Keyword.get(options, :storage_type, :string)

    quote do
      agent do
        persistence :permanent

        schema do
          attribute :actor_id, :string do
            description "Immutable execution principal authenticated by the native scope adapter."
            allow_nil? false
          end

          attribute :storage_id, unquote(storage_type) do
            description "Application destination inherited at creation and only explicitly reconciled thereafter."
            default "initial"
            allow_nil? false
          end

          attribute :storage_replay?, :boolean do
            description "Application opt-in replay setting."
            default false
            allow_nil? false
          end
        end

        route Aikido.InheritedConfigurationTest.SetStorage,
              Aikido.InheritedConfigurationTest.ConfigureStorage, name: :configure_storage
      end

      policies do
        policy always() do
          authorize_if Aikido.InheritedConfigurationTest.ActiveActor
        end

        policy action_type(:update) do
          authorize_if Aikido.InheritedConfigurationTest.OwnExecutionActor
        end

        policy action(:adopt_inherited) do
          authorize_if Aikido.InheritedConfigurationTest.OwnExecutionActor
        end
      end
    end
  end
end

defmodule Aikido.InheritedConfigurationTest.HoldLeafInheritance do
  @moduledoc "Application middleware used to observe the real nested acknowledgement boundary."
  use Aikido.Middleware

  @impl true
  def on_signal(signal, context, _options, next) do
    observer = Process.whereis(Aikido.InheritedConfigurationTest.InheritanceObserver)
    parent = context[:parent]

    if signal.type == "aikido.agent.inherit" && observer && parent &&
         parent.meta[:team_resource] == Aikido.InheritedConfigurationTest.Branch do
      send(observer, {:leaf_inheritance_waiting, self()})

      receive do
        :release_leaf_inheritance -> next.(signal, context)
      after
        5_000 ->
          {:error, context,
           Ash.Error.Action.InvalidArgument.exception(
             field: :state,
             message: "The test did not release its held inherited update."
           )}
      end
    else
      next.(signal, context)
    end
  end
end

defmodule Aikido.InheritedConfigurationTest.Worker do
  use Ash.Resource,
    domain: Aikido.InheritedConfigurationTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension]

  use Aikido.InheritedConfigurationTest.StorageFields

  agent do
    name "inherit_worker"
    middleware [Aikido.InheritedConfigurationTest.HoldLeafInheritance]
  end
end

defmodule Aikido.InheritedConfigurationTest.RejectInitialTopology do
  @moduledoc "A native application pipeline rejection before initial topology changes are adopted."
  use Aikido.Middleware

  @impl true
  def on_signal(signal, context, _options, next) do
    own = context.agent.state.state

    if signal.type == "aikido.ash.team.start" && own.storage_id == "reject-initial" do
      {:error, context,
       Ash.Error.Action.InvalidArgument.exception(
         field: :topology,
         message: "The application rejected this initial topology."
       )}
    else
      next.(signal, context)
    end
  end
end

defmodule Aikido.InheritedConfigurationTest.Branch do
  use Ash.Resource,
    domain: Aikido.InheritedConfigurationTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  use Aikido.InheritedConfigurationTest.StorageFields

  agent do
    name "inherit_branch"
    middleware [Aikido.InheritedConfigurationTest.RejectInitialTopology]
  end

  team do
    inherit [:actor_id, :storage_id, :storage_replay?]
    reconcile_inherit [:storage_id, :storage_replay?]
    member :leaf, Aikido.InheritedConfigurationTest.Worker
  end
end

defmodule Aikido.InheritedConfigurationTest.Root do
  use Ash.Resource,
    domain: Aikido.InheritedConfigurationTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  use Aikido.InheritedConfigurationTest.StorageFields, storage_type: :term

  agent do
    name "inherit_root"
  end

  team do
    inherit [:actor_id, :storage_id, :storage_replay?]
    reconcile_inherit [:storage_id, :storage_replay?]
    worker :branch, Aikido.InheritedConfigurationTest.Branch
    worker :worker, Aikido.InheritedConfigurationTest.Worker
  end
end

defmodule Aikido.InheritedConfigurationTest.OptOut do
  use Ash.Resource,
    domain: Aikido.InheritedConfigurationTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  use Aikido.InheritedConfigurationTest.StorageFields

  agent do
    name "inherit_opt_out"
  end

  team do
    inherit [:actor_id, :storage_id, :storage_replay?]
    worker :worker, Aikido.InheritedConfigurationTest.Worker
  end
end

defmodule Aikido.InheritedConfigurationTest.TenantContext do
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_options),
    do: "the authenticated activation retains its tenant and application context"

  @impl true
  def match?(nil, %{subject: subject}, _options),
    do: subject.tenant == "tenant-only" && get_in(subject.context, [:shared, :boot?]) == true

  def match?(_actor, _context, _options), do: false
end

defmodule Aikido.InheritedConfigurationTest.TenantTeam do
  use Ash.Resource,
    domain: Aikido.InheritedConfigurationTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "inherit_tenant_team"
  end

  team do
  end

  policies do
    policy always() do
      authorize_if Aikido.InheritedConfigurationTest.TenantContext
    end
  end
end

defmodule Aikido.InheritedConfigurationTest.Domain do
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  resources do
    resource Aikido.InheritedConfigurationTest.Access
  end

  agents do
    agent :root, Aikido.InheritedConfigurationTest.Root
    agent :branch, Aikido.InheritedConfigurationTest.Branch
    agent :worker, Aikido.InheritedConfigurationTest.Worker
    agent :opt_out, Aikido.InheritedConfigurationTest.OptOut
    agent :tenant_team, Aikido.InheritedConfigurationTest.TenantTeam
  end
end
