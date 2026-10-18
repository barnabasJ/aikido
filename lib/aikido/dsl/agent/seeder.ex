defmodule Aikido.Dsl.Agent.Seeder do
  @moduledoc false
  alias Aikido.Agent.SliceValidationError
  alias Aikido.Dsl.Slice.Info, as: SliceInfo

  def seed_own(schema, user_value) when schema in [nil, []], do: user_value

  def seed_own(resource, user_value) do
    if Ash.Resource.Info.resource?(resource) do
      # The resource owns the attribute contract. Apply its native casts and
      # defaults without executing a data-layer write or duplicating its schema.
      action = %Ash.Resource.Actions.Create{
        name: :initialize_state,
        accept: Ash.Resource.Info.attribute_names(resource) |> Enum.to_list()
      }

      changeset =
        resource
        |> Ash.Changeset.new()
        |> Ash.Changeset.force_change_attributes(
          Map.take(user_value, Enum.to_list(Ash.Resource.Info.attribute_names(resource)))
        )

      case changeset
           |> Ash.Changeset.for_create(action, %{}, require?: false)
           |> Ash.Changeset.require_values(
             :create,
             false,
             Enum.reject(Ash.Resource.Info.attributes(resource), & &1.allow_nil?)
           )
           |> Ash.Changeset.apply_attributes() do
        {:ok, record} ->
          Map.merge(user_value, Map.take(record, resource.__aikido_state_fields__()))

        {:error, errors} ->
          raise SliceValidationError, path: nil, module: resource, errors: errors
      end
    else
      case Ash.Type.cast_input(resource, user_value) do
        {:ok, value} ->
          Map.merge(user_value, Map.from_struct(value))

        {:error, errors} ->
          raise SliceValidationError, path: nil, module: resource, errors: errors
      end
    end
  end

  def seed_mount(slice_module, %{} = input, path) when is_atom(path) do
    schema = SliceInfo.schema(slice_module)

    result =
      cond do
        schema in [nil, []] ->
          {:ok, input}

        Ash.Resource.Info.resource?(schema) ->
          Ash.Type.cast_input(schema, input, skip_unknown_inputs: [:*])

        true ->
          Ash.Type.cast_input(schema, input)
      end

    result =
      case result do
        {:ok, value} ->
          value =
            if is_struct(value) &&
                 is_nil(Spark.Dsl.Extension.get_persisted(slice_module, :aikido_slice_schema)),
               do: Map.take(value, Ash.Resource.Info.attribute_names(schema) |> Enum.to_list()),
               else: value

          case Spark.Dsl.Extension.get_opt(slice_module, [:slice], :state_transform) do
            nil ->
              {:ok, value}

            {module, function, args} ->
              case apply(module, function, [value, [] | args]) do
                {:ok, _} = result -> result
                {:error, _} = error -> error
                value -> {:ok, value}
              end
          end

        error ->
          error
      end

    case result do
      {:ok, value} ->
        value

      {:error, _} when map_size(input) == 0 ->
        nil

      {:error, errors} ->
        raise SliceValidationError, path: path, module: slice_module, errors: errors

      :error when map_size(input) == 0 ->
        nil

      :error ->
        raise SliceValidationError, path: path, module: slice_module, errors: "invalid state"
    end
  end
end
