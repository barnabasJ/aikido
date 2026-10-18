defmodule Aikido.Ash.Attributes do
  @moduledoc false

  # The resource attributes are the source of truth. The pure runtime consumes
  # their Ash type contracts without depending on a second schema declaration.
  def fields(attributes, opts \\ []) do
    Enum.map(attributes, fn attribute ->
      fields = [
        type: attribute.type,
        constraints: attribute.constraints,
        allow_nil?: attribute.allow_nil?,
        default: attribute.default,
        description: attribute.description
      ]

      fields =
        if Keyword.get(opts, :defaults?, true), do: fields, else: Keyword.delete(fields, :default)

      {attribute.name, Enum.reject(fields, fn {_key, value} -> is_nil(value) end)}
    end)
  end
end
