defmodule AikidoTest.DurableScopeAgent.Signals.Rebind do
  @moduledoc "Typed replacement identity and credential supplied by the authenticated test boundary."
  use Aikido.Signal

  signal do
    type "durable_scope.rebind"

    schema do
      attribute :actor_id, :string do
        description "Authenticated replacement identity."
        allow_nil? false
      end

      attribute :credential, :string do
        description "Opaque credential issued at the external application boundary."
        allow_nil? false
        sensitive? true
      end
    end
  end
end

defmodule AikidoTest.DurableScopeAgent.Actions.Rebind do
  @moduledoc "Adopts a matching scoped identity and its replacement credential in one reducer result."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, context) do
    if context.actor && context.actor.id == input.arguments.actor_id do
      Aikido.Types.ActionResult.new(
        changes: %{
          actor_id: input.arguments.actor_id,
          execution_credential: input.arguments.credential
        }
      )
    else
      {:error, :identity_mismatch}
    end
  end
end

defmodule AikidoTest.DurableScopeAgent.Actions.RecordBoot do
  @moduledoc "Records the authority observed by the native routed lifecycle action."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _, context) do
    Aikido.Types.ActionResult.new(changes: %{boot_actor: context.actor})
  end
end

defmodule AikidoTest.DurableScopeAgent.Changes.RecordInitialization do
  @moduledoc "Reports actual native initialization to the test observer."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _, context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      if observer = get_in(changeset.context, [:shared, :observer]) do
        send(observer, {:durable_native_initialize, context.actor.id})
      end

      {:ok, record}
    end)
  end
end

defmodule AikidoTest.DurableScopeAgent do
  @moduledoc "An authenticated agent fixture exercising native initialization, restore and identity rebinding."
  use Aikido.Agent, authorizers: [Ash.Policy.Authorizer]

  agent do
    name "durable_scope_agent"

    schema do
      attribute :actor_id, :string do
        description "Canonical identity used by the external authority's binding checks."
        allow_nil? false
      end

      attribute :execution_credential, :string do
        description "Opaque replacement credential adopted atomically with a new identity."
        sensitive? true
      end

      attribute :boot_actor, :map do
        description "Current authority observed by the routed lifecycle action."
        default %{}
      end
    end

    route Aikido.AgentServer.Signals.LifecycleReady,
          AikidoTest.DurableScopeAgent.Actions.RecordBoot,
          public?: false

    route AikidoTest.DurableScopeAgent.Signals.Rebind,
          AikidoTest.DurableScopeAgent.Actions.Rebind,
          public?: false
  end

  changes do
    change AikidoTest.DurableScopeAgent.Changes.RecordInitialization, on: [:create]
  end

  policies do
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:allowed, true)
    end

    policy action_type(:action) do
      authorize_if always()
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:allowed, true)
    end
  end

  @behaviour Aikido.Durable.Codec

  @impl true
  def externalize(state), do: Map.put(state, :execution_credential, nil)

  @impl true
  def reinstate(state), do: state
end
