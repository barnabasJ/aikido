defmodule AgentExamples.DurableScope do
  @moduledoc """
  Restores the playground's existing browser identity through Phoenix signing trust.

  This local example accepts the browser actor and playground tenant already used
  by commands. It creates no principals or grants and stores no caller scope.
  Signed credentials expire after 30 days; endpoint key rotation invalidates them.
  Individual revocation is outside this playground's authorization model.
  """
  @behaviour Aikido.Durable.ScopeAdapter

  @salt "agent-examples-durable-scope-v1"
  @max_age 30 * 24 * 60 * 60
  @scope_keys [:actor, :tenant, :context, :authorize?, :tracer]
  @identity_keys [:agent_module, :id, :aikido, :partition, :durable_server, :durable_key]

  @impl true
  def prepare(attributes, options, identity) do
    scope = Map.new(options)

    if supported_scope?(scope) && valid_identity?(identity) do
      prepare_browser_credential(attributes, scope, identity)
    else
      {:error, :unsupported_playground_scope}
    end
  end

  defp supported_scope?(scope) do
    Map.keys(scope) -- @scope_keys == [] && scope[:context] in [nil, %{}] &&
      scope[:authorize?] in [nil, true] && scope[:tracer] in [nil, []]
  end

  defp valid_identity?(identity) when is_map(identity),
    do: Enum.sort(Map.keys(identity)) == Enum.sort(@identity_keys)

  defp valid_identity?(_identity), do: false

  defp prepare_browser_credential(
         attributes,
         %{actor: %{id: owner} = actor, tenant: "playground"},
         identity
       )
       when is_binary(owner) and byte_size(owner) > 0 and map_size(actor) == 1 do
    payload = %{version: 1, owner: owner, tenant: "playground", identity: identity}
    credential = Phoenix.Token.sign(AgentExamplesWeb.Endpoint, @salt, payload)
    {:ok, attributes, credential}
  end

  defp prepare_browser_credential(attributes, scope, _identity) do
    if is_nil(scope[:actor]) && is_nil(scope[:tenant]),
      do: {:ok, attributes, nil},
      else: {:error, :unsupported_playground_scope}
  end

  @impl true
  def restore(nil, _saved, identity) do
    if valid_identity?(identity),
      do: {:ok, %{}},
      else: {:error, :invalid_playground_credential}
  end

  def restore(credential, _saved, identity) when is_binary(credential) do
    case Phoenix.Token.verify(AgentExamplesWeb.Endpoint, @salt, credential, max_age: @max_age) do
      {:ok, %{version: 1, owner: owner, tenant: "playground", identity: ^identity}}
      when is_binary(owner) and byte_size(owner) > 0 ->
        if valid_identity?(identity) do
          {:ok, %{actor: %{id: owner}, tenant: "playground", context: %{}, authorize?: true}}
        else
          {:error, :invalid_playground_credential}
        end

      _ ->
        {:error, :invalid_playground_credential}
    end
  end

  def restore(_credential, _saved, _identity),
    do: {:error, :invalid_playground_credential}

  @impl true
  def checkpoint(agent, credential, identity) do
    if agent.id == identity[:id] && agent.agent_module == identity[:agent_module] do
      with {:ok, _scope} <- restore(credential, {:agent, agent}, identity) do
        {:ok, credential}
      end
    else
      {:error, :playground_identity_mismatch}
    end
  end
end
