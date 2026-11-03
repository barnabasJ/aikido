defmodule Aikido.Durable.MountedSchema do
  @moduledoc """
  Rematerialize physically older mounted records through their owning native actions.

  Opaque application checkpoints retain the original struct's actual field set.
  Native embedded casting restores current layouts for nested typed values; only
  attributes physically present in the saved record are supplied to create, so
  native defaults apply to newly declared fields. Explicit nils remain supplied.
  This does not recover field presence already lost by an earlier typed decode.
  """

  def restore(agent, resource, scope) do
    state =
      Enum.reduce(Aikido.Agent.Info.slice_instances(resource), agent.state, fn instance, state ->
        case Map.fetch(state, instance.path) do
          {:ok, value} when is_map(value) ->
            Map.put(state, instance.path, restore_record(value, instance.module, scope))

          _ ->
            state
        end
      end)

    %{agent | state: restore_own(state, agent.id, resource, scope)}
  end

  defp restore_record(value, resource, scope) do
    attributes = Ash.Resource.Info.attributes(resource)
    fields = Enum.map(attributes, & &1.name)

    if Enum.all?(fields, &Map.has_key?(value, &1)) do
      value
    else
      present = Enum.filter(fields, &Map.has_key?(value, &1))
      {:ok, dumped} = Ash.Type.dump_to_embedded(resource, value)
      {:ok, decoded} = Ash.Type.cast_from_embedded(resource, dumped)

      resource
      |> Ash.Changeset.for_create(:create, Map.take(decoded, present), scope)
      |> Ash.create!(scope)
    end
  end

  defp restore_own(state, id, resource, scope) do
    path = Aikido.Agent.Info.agent_path!(resource)
    values = Map.get(state, path, %{})
    fields = Aikido.Agent.Info.state_fields(resource)

    if Enum.all?(fields, &Map.has_key?(values, &1)) do
      state
    else
      record =
        resource
        |> Ash.Changeset.for_create(:__aikido_initialize_state__, Map.put(values, :id, id), scope)
        |> Ash.create!(scope)

      Map.put(state, path, Map.take(record, fields))
    end
  end
end
