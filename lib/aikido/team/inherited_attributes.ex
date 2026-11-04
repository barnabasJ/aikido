defmodule Aikido.Team.InheritedAttributes do
  @moduledoc "Own-state attributes that may participate in explicit inherited configuration."

  @identity_fields [
    :id,
    :agent_id,
    :actor,
    :actor_id,
    :org_id,
    :thread_id,
    :principal_id,
    :definition_ref,
    :execution_credential,
    :tenant,
    :tenant_id,
    :scope,
    :context,
    :credential,
    :credentials,
    :execution_identity,
    :execution_scope,
    :bound_execution_scope,
    :aikido,
    :partition,
    :durable_key,
    :durable_server,
    :parent,
    :owner,
    :owner_id
  ]

  @doc "Identity and sensitive fields cannot become mutable inherited configuration."
  def restricted_attribute?(attribute),
    do: attribute.primary_key? || attribute.sensitive? || attribute.name in @identity_fields

  @doc "Validate only schema ownership and policy; native Ash adoption casts the supplied values."
  def validate(resource, fields) do
    own_fields = Aikido.Agent.Info.state_fields(resource)

    permitted? =
      Enum.all?(fields, fn field ->
        case Ash.Resource.Info.attribute(resource, field) do
          nil ->
            false

          attribute ->
            field in own_fields && attribute.writable? && !restricted_attribute?(attribute)
        end
      end)

    if !permitted? do
      {:error,
       Ash.Error.Action.InvalidArgument.exception(
         field: :changes,
         message:
           "Inherited configuration may only change declared writable, nonsensitive own-state attributes outside agent identity."
       )}
    else
      :ok
    end
  end
end
