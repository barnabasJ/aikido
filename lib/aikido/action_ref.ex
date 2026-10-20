defmodule Aikido.ActionRef do
  @moduledoc "Payload introspection for native `{resource, action}` references."

  def schema({resource, action}), do: resource |> Ash.Resource.Info.action(action) |> schema()

  def schema(%{arguments: arguments}) do
    case Enum.find(arguments, &(&1.name == :data)) do
      nil ->
        for argument <- arguments,
            argument.name != :state,
            do:
              {argument.name,
               Map.take(argument, [
                 :type,
                 :constraints,
                 :allow_nil?,
                 :default,
                 :description,
                 :sensitive?
               ])
               |> Map.to_list()}

      data ->
        Keyword.get(data.constraints, :fields, [])
    end
  end

  def schema(_), do: []
end
