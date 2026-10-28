defmodule AikidoTest.DurableScopeAuthority do
  @moduledoc "A revocable external credential authority used by native durable integration tests."
  @behaviour Aikido.Durable.ScopeAdapter

  def start_link do
    Agent.start_link(fn -> %{sessions: %{}, actors: %{}} end, name: __MODULE__)
  end

  @impl true
  def prepare(attributes, options, identity) do
    scope = Map.new(options)
    actor = scope[:actor]

    if is_nil(actor) && requires_fresh_actor?(attributes, scope, identity) do
      {:error, :missing_execution_actor}
    else
      prepare_authenticated(attributes, scope, actor, identity)
    end
  end

  # Explicit application policy for the protected test resources, before a durable claim.
  defp requires_fresh_actor?(attributes, scope, identity) do
    case identity[:agent_module] do
      AikidoTest.DurableScopeAgent -> true
      Aikido.NativeRuntimeScopeTest.Resource -> scope[:authorize?] != false
      _ -> not is_nil(bound_actor({:uninitialized, attributes}))
    end
  end

  defp prepare_authenticated(attributes, scope, actor, identity) do
    actor_key = actor_key(actor, scope[:tenant])
    credential = Ash.UUIDv7.generate()

    Agent.update(__MODULE__, fn state ->
      state
      |> update_in([:actors], &Map.put_new(&1, actor_key, actor))
      |> put_in([:sessions, credential], %{
        identity: identity,
        actor_key: actor_key,
        scope: Map.delete(scope, :actor),
        revoked?: false
      })
    end)

    {:ok, attributes, credential}
  end

  @impl true
  def restore(credential, saved, identity) do
    with {:ok, scope} <- validate_credential(credential, saved, identity) do
      if observer = get_in(scope, [:context, :shared, :observer]) do
        send(observer, {:durable_authentication, identity})
      end

      {:ok, scope}
    end
  end

  defp validate_credential(credential, saved, identity) do
    Agent.get(__MODULE__, fn state ->
      with %{revoked?: false, identity: ^identity} = session <- state.sessions[credential],
           actor = state.actors[session.actor_key],
           true <- is_nil(actor) || Map.get(actor, :allowed, true),
           true <- bound_actor(saved) in [nil, actor && actor.id] do
        {:ok, Map.put(session.scope, :actor, actor)}
      else
        _ -> {:error, :invalid_or_revoked_credential}
      end
    end)
  end

  @impl true
  def checkpoint(agent, credential, identity) do
    attributes = Aikido.Agent.resource_attributes(agent)
    credential = Map.get(attributes, :execution_credential) || credential

    with {:ok, _scope} <- validate_credential(credential, {:agent, agent}, identity) do
      {:ok, credential}
    end
  end

  @doc "Application I/O boundary validates a replacement before dispatching its pure transition."
  def rebind(pid, actor, credential, identity) do
    proposed = {:uninitialized, %{state: %{actor_id: actor.id}}}

    with {:ok, %{actor: %{id: current_id}} = scope} <-
           validate_credential(credential, proposed, identity),
         true <- current_id == actor.id || {:error, :identity_mismatch} do
      signal =
        AikidoTest.DurableScopeAgent.Signals.Rebind.new!(
          %{actor_id: actor.id, credential: credential},
          scope: scope
        )

      Aikido.AgentServer.call(pid, signal, fn runtime ->
        own = Aikido.Agent.resource_attributes(runtime.agent)
        {:ok, {own.actor_id, own.execution_credential}}
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :identity_mismatch}
    end
  end

  def revoke(credential) do
    Agent.update(__MODULE__, &put_in(&1, [:sessions, credential, :revoked?], true))
  end

  def refresh_actor(actor, tenant) do
    Agent.update(__MODULE__, &put_in(&1, [:actors, actor_key(actor, tenant)], actor))
  end

  defp actor_key(nil, tenant), do: {nil, tenant, nil}
  defp actor_key(actor, tenant), do: {actor.id, tenant, Map.get(actor, :mode)}

  defp bound_actor({:uninitialized, attributes}) do
    attributes
    |> Map.values()
    |> Enum.find_value(fn
      value when is_map(value) -> Map.get(value, :actor_id)
      _ -> nil
    end)
  end

  defp bound_actor({:agent, agent}),
    do: Map.get(Aikido.Agent.resource_attributes(agent), :actor_id)

  defp bound_actor({:checkpoint, _checkpoint}), do: nil
end

defmodule AikidoTest.DurableProtocolScope do
  @moduledoc "Native scope whose context and tracers have no conventional field names."
  defstruct [:principal, :organization, :payload, :trace_modules]

  defimpl Ash.Scope.ToOpts do
    def get_actor(scope), do: {:ok, scope.principal}
    def get_tenant(scope), do: {:ok, scope.organization}
    def get_context(scope), do: {:ok, scope.payload}
    def get_tracer(scope), do: {:ok, scope.trace_modules}
    def get_authorize?(_), do: {:ok, true}
  end
end

defmodule AikidoTest.DurableProtocolAuthority do
  @moduledoc "Returns a custom native scope from the authenticated external authority."
  @behaviour Aikido.Durable.ScopeAdapter

  @impl true
  defdelegate prepare(attributes, options, identity), to: AikidoTest.DurableScopeAuthority
  @impl true
  defdelegate checkpoint(agent, credential, identity), to: AikidoTest.DurableScopeAuthority

  @impl true
  def restore(credential, saved, identity) do
    with {:ok, scope} <- AikidoTest.DurableScopeAuthority.restore(credential, saved, identity) do
      {:ok,
       %AikidoTest.DurableProtocolScope{
         principal: scope.actor,
         organization: scope.tenant,
         payload: scope.context,
         trace_modules: scope[:tracer]
       }}
    end
  end
end
