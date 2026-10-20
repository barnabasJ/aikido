defmodule Aikido.Agent.Initialize do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, opts, _context) do
    path = opts[:path]
    instances = opts[:slices] || []
    paths = Enum.map(instances, & &1.path)
    user = input.arguments.state
    known = [path | paths]

    user =
      if path && map_size(user) > 0 && !Enum.any?(Map.keys(user), &(&1 in known)),
        do: %{path => user},
        else: user

    state =
      Enum.reduce(instances, Map.drop(user, known), fn instance, state ->
        values = Map.merge(instance.config || %{}, Map.get(user, instance.path) || %{})
        Map.put(state, instance.path, create_slice(instance.module, values, instance.path))
      end)

    state =
      if path,
        do:
          Map.put(
            state,
            path,
            create_own(input.resource, Map.get(user, path) || %{}, input.arguments.id)
          ),
        else: state

    Aikido.Agent.new(
      id: input.arguments.id,
      agent_module: input.resource,
      name: Spark.Dsl.Extension.get_opt(input.resource, [:agent], :name),
      description: Spark.Dsl.Extension.get_opt(input.resource, [:agent], :description),
      state: state
    )
  end

  defp create_own(resource, values, id) do
    result =
      if Aikido.Ash.Agent in Spark.extensions(resource) do
        resource
        |> Ash.Changeset.for_create(:__aikido_initialize_state__, Map.put(values, :id, id),
          skip_unknown_inputs: [:*],
          authorize?: false
        )
        |> Ash.Changeset.apply_attributes()
      else
        Ash.create(resource, values, authorize?: false, skip_unknown_inputs: [:*])
      end

    case result do
      {:ok, record} ->
        Map.merge(values, Map.take(record, Aikido.Dsl.Agent.Info.state_fields(resource)))

      {:error, error} ->
        raise Aikido.Agent.SliceValidationError, path: nil, module: resource, errors: error
    end
  end

  defp create_slice(module, values, path) do
    schema = Aikido.Dsl.Slice.Info.schema(module)

    result =
      cond do
        schema in [nil, []] ->
          {:ok, values}

        Ash.Resource.Info.resource?(schema) ->
          Ash.create(schema, values, authorize?: false, skip_unknown_inputs: [:*])

        true ->
          Ash.Type.cast_input(schema, values)
      end

    with {:ok, value} <- result do
      value =
        if is_struct(value) &&
             is_nil(Spark.Dsl.Extension.get_persisted(module, :aikido_slice_schema)),
           do: Map.take(value, Enum.to_list(Ash.Resource.Info.attribute_names(schema))),
           else: value

      case Spark.Dsl.Extension.get_opt(module, [:slice], :state_transform) do
        nil ->
          value

        {module, function, args} ->
          case apply(module, function, [value, [] | args]) do
            {:ok, value} ->
              value

            {:error, error} ->
              raise Aikido.Agent.SliceValidationError, path: path, module: module, errors: error

            value ->
              value
          end
      end
    else
      {:error, _} when map_size(values) == 0 ->
        nil

      {:error, error} ->
        raise Aikido.Agent.SliceValidationError, path: path, module: module, errors: error
    end
  end
end
