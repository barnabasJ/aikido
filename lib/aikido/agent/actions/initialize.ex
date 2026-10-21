defmodule Aikido.Agent.Actions.Initialize do
  @moduledoc """
  Builds an immutable agent from its `id` and initial `state` arguments.

  The configured `:path` and `:slices` options identify the own-state path and
  mounts. Native create actions run with caller scope, authorization and hooks.
  The own-state action uses this module's manual create callback to build a
  record without writing to the resource's independent data layer. Mounted
  embedded slices use their native create actions; the result is an `Aikido.Agent`.
  """
  use Ash.Resource.Actions.Implementation
  use Ash.Resource.ManualCreate

  @impl true
  def run(input, opts, context) do
    path = opts[:path]
    instances = opts[:slices] || []
    user = input.arguments.state
    known = [path | Enum.map(instances, & &1.path)]
    scope = Ash.Scope.to_opts(context, context: input.context)

    user =
      if map_size(user) > 0 && !Enum.any?(Map.keys(user), &(&1 in known)),
        do: %{path => user},
        else: user

    with {:ok, record} <-
           initialize(
             input.resource,
             :__aikido_initialize_state__,
             Map.put(Map.get(user, path) || %{}, :id, input.arguments.id),
             path,
             scope
           ),
         {:ok, state} <- initialize_slices(instances, user, scope) do
      state =
        Map.put(state, path, Map.take(record, Aikido.Agent.Info.state_fields(input.resource)))

      Aikido.Agent.new(
        id: input.arguments.id,
        agent_module: input.resource,
        name: Spark.Dsl.Extension.get_opt(input.resource, [:agent], :name),
        description: Spark.Dsl.Extension.get_opt(input.resource, [:agent], :description),
        state: state
      )
    end
  end

  @impl Ash.Resource.ManualCreate
  def create(changeset, _opts, _context), do: Ash.Changeset.apply_attributes(changeset)

  defp initialize_slices(instances, values, scope) do
    Enum.reduce_while(instances, {:ok, %{}}, fn instance, {:ok, state} ->
      attributes = Map.merge(instance.config, Map.get(values, instance.path) || %{})

      case initialize(instance.module, :create, attributes, instance.path, scope) do
        {:ok, record} -> {:cont, {:ok, Map.put(state, instance.path, record)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp initialize(resource, action, values, path, scope) do
    resource
    |> Ash.Changeset.for_create(action, values, Keyword.put(scope, :skip_unknown_inputs, [:*]))
    |> Ash.create(scope)
    |> case do
      {:ok, record} -> {:ok, record}
      {:error, errors} -> {:error, Ash.Error.to_error_class(Ash.Error.set_path(errors, [path]))}
    end
  end
end
