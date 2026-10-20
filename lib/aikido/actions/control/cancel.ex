defmodule Aikido.Actions.Control.Cancel do
  @moduledoc """
  Pure reducer that marks the supplied `state` as failed with a cancellation reason.

  Preserves unrelated fields, validates resource attributes through Ash when state
  is a struct, and returns the updated state without directives.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    changes = %{status: :failed, error: {:cancelled, input.arguments.reason}}

    case input.arguments.state do
      %_{} = state ->
        changeset = state |> Ash.Changeset.new() |> Ash.Changeset.change_attributes(changes)

        if changeset.valid? do
          Aikido.Types.ActionResult.new(state: struct!(state, changeset.attributes))
        else
          {:error, Ash.Error.to_error_class(changeset.errors)}
        end

      state when is_map(state) ->
        Aikido.Types.ActionResult.new(state: Map.merge(state, changes))
    end
  end
end
