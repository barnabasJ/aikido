defmodule Aikido.Types.Directive do
  @moduledoc "A directive struct whose module implements `Aikido.Directive`."
  use Ash.Type

  @impl true
  def storage_type(_), do: :term

  @impl true
  def cast_input(%module{} = value, _) do
    with {:ok, _module} <-
           Ash.Type.apply_constraints(:module, module, behaviour: Aikido.Directive) do
      if Spark.Dsl.is?(module, Aikido.Directive),
        do: module.new(Map.from_struct(value)),
        else: {:error, message: "must use Aikido.Directive for its typed contract"}
    end
  end

  def cast_input(_value, _constraints),
    do: {:error, message: "must be a struct implementing Aikido.Directive"}

  @impl true
  def cast_stored(value, constraints), do: cast_input(value, constraints)

  @impl true
  def dump_to_native(value, constraints), do: cast_input(value, constraints)
end
