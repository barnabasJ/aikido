defmodule Aikido.Durable.ScopeAdapter do
  @moduledoc """
  Application-owned authentication at the durable activation boundary.

  Configure `:scope_adapter` on the Aikido runtime's `:durable` options. The
  adapter belongs to the application's I/O boundary, not its pure agent resource.
  Aikido never infers authority from saved attribution fields.

  `prepare/3` receives initial state, native Ash caller options and the logical
  activation identity. It returns recoverable bootstrap attributes with secrets
  and transient values removed, plus an opaque, revocable credential. Preparation
  may race; it must not start agent work. An unused credential from a losing start
  is permitted. The credential and attributes are encoded using native Ash types.

  `restore/3` runs after DurableServer claims the identity. Its second argument is
  either `{:uninitialized, attributes}` or the resource's existing saved agent or
  checkpoint tuple. Authenticate the credential, refresh current permissions and
  check the complete expected identity before returning a native Ash scope.

  `checkpoint/3` receives the live agent before path codecs remove transient
  authority. Return the opaque credential for that exact identity. Applications
  that rebind identities must adopt a replacement credential in the same native
  action as their binding changes; this callback must reject stale bindings.

  Only opaque credentials are persisted. Actor structs and caller scopes must
  never be returned as credentials or bootstrap attributes. Credentials must not
  appear in tool context, projections, logs or errors. Agent-wide checkpoint and
  restore callbacks retain their existing two-element result contracts.
  """

  @type identity :: map()
  @type credential :: term()

  @callback prepare(map(), keyword(), identity()) ::
              {:ok, map(), credential()} | {:error, term()}
  @callback restore(credential(), term(), identity()) :: {:ok, term()} | {:error, term()}
  @callback checkpoint(Aikido.Agent.t(), credential(), identity()) ::
              {:ok, credential()} | {:error, term()}

  @doc false
  def identity(options),
    do:
      options
      |> Map.new()
      |> Map.take([:agent_module, :id, :aikido, :partition, :durable_server, :durable_key])

  @doc false
  def restore(nil, nil, _saved, _identity), do: {:ok, []}

  def restore(nil, _credential, _saved, _identity),
    do: {:error, :scope_adapter_required}

  def restore(adapter, credential, saved, identity) do
    with {:ok, scope} <- adapter.restore(credential, saved, identity) do
      options =
        if is_struct(scope),
          do: Ash.Scope.to_opts(scope),
          else: Ash.Scope.to_opts(scope, context: Map.get(scope, :context, %{}))

      {:ok, options}
    end
  end

  @doc false
  def checkpoint(nil, nil, _agent, _identity), do: nil

  def checkpoint(adapter, credential, agent, identity) do
    case adapter.checkpoint(agent, credential, identity) do
      {:ok, next} ->
        next

      {:error, reason} ->
        raise Aikido.Durable.ScopeAdapter.Error, operation: :checkpoint, reason: reason
    end
  end
end
