defmodule Aikido.Types.Directive do
  @moduledoc "An executable directive with a concrete DirectiveExec implementation."
  use Ash.Type

  @impl true
  def storage_type(_), do: :term

  @impl true
  def cast_input(value, _) do
    case Aikido.AgentServer.DirectiveExec.impl_for(value) do
      Aikido.AgentServer.DirectiveExec.Any ->
        {:error, message: "must have a concrete Aikido.AgentServer.DirectiveExec implementation"}

      _ ->
        {:ok, value}
    end
  end

  @impl true
  def cast_stored(value, constraints), do: cast_input(value, constraints)

  @impl true
  def dump_to_native(value, constraints), do: cast_input(value, constraints)
end
