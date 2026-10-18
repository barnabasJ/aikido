defmodule Aikido.ActionRef do
  @moduledoc "Introspection of native Ash actions referenced by `{resource, action}`."

  def normalize({resource, action}) when is_atom(resource) and is_atom(action),
    do: {resource, action}

  def normalize(resource) when is_atom(resource) do
    case Enum.filter(Ash.Resource.Info.actions(resource), &(&1.type == :action)) do
      [%{name: name}] ->
        {resource, name}

      _ ->
        raise ArgumentError, "Use {resource, action} when a resource has multiple generic actions"
    end
  end

  def definition(reference) do
    {resource, action} = normalize(reference)
    Ash.Resource.Info.action(resource, action)
  end

  def valid?(reference) do
    {resource, _} = normalize(reference)

    Code.ensure_loaded?(resource) && Spark.Dsl.is?(resource, Ash.Resource) &&
      match?(%{type: :action}, definition(reference))
  rescue
    _ -> false
  end

  def schema(reference) do
    case definition(reference) do
      %{arguments: arguments} ->
        case Enum.find(arguments, &(&1.name == :data)) do
          nil ->
            arguments
            |> Enum.reject(&(&1.name == :state))
            |> Enum.map(&{&1.name, field_options(&1)})

          data ->
            Keyword.get(data.constraints, :fields, [])
        end

      _ ->
        []
    end
  end

  defp field_options(argument) do
    Keyword.new(
      [:type, :constraints, :allow_nil?, :default, :description],
      &{&1, Map.get(argument, &1)}
    )
  end
end
