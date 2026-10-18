defmodule Aikido.Types.Union do
  @moduledoc "Ash type for untagged runtime identifiers accepted in several native forms."
  use Ash.Type
  def storage_type(_), do: :term
  def constraints, do: [types: [type: {:list, :any}, required: true]]

  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, constraints) do
    Enum.reduce_while(constraints[:types], :error, fn opts, _ ->
      # Keep an existing native form before attempting coercion.
      type = opts[:type]
      matches? = Ash.Type.matches_type?(type, value, opts[:constraints] || [])

      if matches? do
        case Aikido.Schema.cast_value(type, value, opts[:constraints] || []) do
          {:ok, value} -> {:halt, {:ok, value}}
          _ -> {:cont, :error}
        end
      else
        {:cont, :error}
      end
    end)
  end

  def cast_stored(value, constraints), do: cast_input(value, constraints)
  def dump_to_native(value, _), do: {:ok, value}
end
