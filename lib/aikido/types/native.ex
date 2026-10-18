defmodule Aikido.Types.Native do
  @moduledoc "Ash type for BEAM values validated by Spark's native option validators."
  use Ash.Type
  def storage_type(_), do: :term
  def constraints, do: [kind: [type: :any, required: true]]

  def matches_type?(value, constraints), do: match?({:ok, _}, cast_input(value, constraints))

  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, constraints) do
    case Spark.Options.validate([value: value], value: [type: constraints[:kind], required: true]) do
      {:ok, values} -> {:ok, values[:value]}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  def cast_stored(value, constraints), do: cast_input(value, constraints)
  def dump_to_native(value, _), do: {:ok, value}
end
