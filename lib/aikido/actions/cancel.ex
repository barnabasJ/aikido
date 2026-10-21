defmodule Aikido.Actions.Cancel do
  @moduledoc """
  Pure reducer that marks the supplied `state` as failed with a cancellation reason.

  Preserves unrelated fields, validates resource attributes through Ash when state
  is a struct, and returns the updated state without directives.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    changes = %{status: :failed, error: {:cancelled, input.arguments.reason}}

    with {:ok, state} <- apply_cancellation_changes(input.arguments.state, changes) do
      Aikido.Types.ActionResult.new(state: state)
    end
  end

  defp apply_cancellation_changes(%_{} = state, changes) do
    state
    |> Ash.Changeset.new()
    |> Ash.Changeset.change_attributes(changes)
    |> adopt_validated_changes(state)
  end

  defp apply_cancellation_changes(state, changes) when is_map(state),
    do: {:ok, Map.merge(state, changes)}

  defp adopt_validated_changes(%{valid?: true, attributes: attributes}, state),
    do: {:ok, Map.merge(state, attributes)}

  defp adopt_validated_changes(%{errors: errors}, _state),
    do: {:error, Ash.Error.to_error_class(errors)}
end
