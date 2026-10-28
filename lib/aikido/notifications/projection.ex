defmodule Aikido.Notifications.Projection do
  @moduledoc """
  Composes explicitly declared native notification calculations.

  A resource contributes only its `:notification_data` calculation. Mounted
  calculations remain owned by their embedded resources and are loaded through
  Ash's nested attribute loads. Ordinary resource attributes are never exported
  as a fallback.
  """

  @doc "Build projection metadata for the root and each opted-in mounted slice."
  def definitions(resource, mounts, own_path) do
    root = definition(resource, own_path, :root)

    slices =
      Enum.flat_map(mounts, fn mount ->
        definition(mount.module, mount.path, :mount)
      end)

    root ++ slices
  end

  @doc "Return native map fields using each calculation's declared type contract."
  def fields(definitions) do
    Enum.map(definitions, fn definition ->
      {definition.path,
       [
         type: definition.type,
         constraints: definition.constraints,
         allow_nil?: definition.allow_nil?
       ]}
    end)
  end

  @doc "Return native Ash loads for all contributing calculations."
  def loads(definitions) do
    Enum.map(definitions, fn
      %{location: :root, name: name} -> name
      %{location: :mount, path: path, name: name} -> {path, [name]}
    end)
  end

  @doc "Project already-loaded calculation values under their owning state paths."
  def project(record, definitions) do
    Map.new(definitions, fn definition ->
      source =
        case definition.location do
          :root -> record
          :mount -> Map.fetch!(record, definition.path)
        end

      {definition.path, calculation_value(source, definition)}
    end)
  end

  defp definition(resource, path, location) do
    case Ash.Resource.Info.calculation(resource, :notification_data) do
      nil ->
        []

      calculation ->
        [
          %{
            resource: resource_module(resource),
            path: path,
            location: location,
            name: calculation.name,
            type: calculation.type,
            constraints: calculation.constraints,
            allow_nil?: calculation.allow_nil?,
            field?: calculation.field?
          }
        ]
    end
  end

  defp resource_module(resource) when is_atom(resource), do: resource

  defp resource_module(dsl), do: Spark.Dsl.Transformer.get_persisted(dsl, :module)

  defp calculation_value(nil, _definition), do: nil

  defp calculation_value(record, %{field?: false, name: name}),
    do: Map.fetch!(record.calculations, name)

  defp calculation_value(record, %{name: name}), do: Map.fetch!(record, name)
end
