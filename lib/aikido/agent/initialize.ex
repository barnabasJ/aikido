defmodule Aikido.Agent.Initialize do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, opts, _context) do
    path = opts[:path]
    instances = opts[:slices] || []
    user = input.arguments.state
    known = [path | Enum.map(instances, & &1.path)]

    user =
      if map_size(user) > 0 && !Enum.any?(Map.keys(user), &(&1 in known)),
        do: %{path => user},
        else: user

    with {:ok, record} <-
           initialize(
             input.resource,
             :__aikido_initialize_state__,
             Map.put(Map.get(user, path) || %{}, :id, input.arguments.id),
             path
           ),
         {:ok, state} <- initialize_slices(instances, user) do
      state =
        Map.put(state, path, Map.take(record, Aikido.Dsl.Agent.Info.state_fields(input.resource)))

      Aikido.Agent.new(
        id: input.arguments.id,
        agent_module: input.resource,
        name: Spark.Dsl.Extension.get_opt(input.resource, [:agent], :name),
        description: Spark.Dsl.Extension.get_opt(input.resource, [:agent], :description),
        state: state
      )
    end
  end

  defp initialize_slices(instances, values) do
    Enum.reduce_while(instances, {:ok, %{}}, fn instance, {:ok, state} ->
      attributes = Map.merge(instance.config, Map.get(values, instance.path) || %{})

      case initialize(instance.module, :create, attributes, instance.path) do
        {:ok, record} -> {:cont, {:ok, Map.put(state, instance.path, record)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp initialize(resource, action, values, path) do
    resource
    |> Ash.Changeset.for_create(action, values, skip_unknown_inputs: [:*], authorize?: false)
    |> Ash.Changeset.apply_attributes()
    |> case do
      {:ok, record} -> {:ok, record}
      {:error, errors} -> {:error, Ash.Error.to_error_class(Ash.Error.set_path(errors, [path]))}
    end
  end
end
