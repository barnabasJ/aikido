defmodule Aikido.Memory.Spaces do
  @moduledoc "Shared space lookup and revision bookkeeping for native memory reducers."

  def fetch(input, kind \\ nil) do
    name = input.arguments.space

    case Map.get(input.arguments.state.spaces, name) do
      %Aikido.Memory.Types.Space{data: data} = space
      when is_nil(kind) or (kind == :map and is_map(data)) or
             (kind == :list and is_list(data)) ->
        {:ok, space}

      nil ->
        invalid_space_argument(input, "space #{inspect(name)} does not exist")

      _ ->
        invalid_space_argument(input, "space #{inspect(name)} is not a #{kind || :valid} space")
    end
  end

  @doc "Return updated spaces with the next revision and the input signal’s timestamp."
  def replace_spaces_and_advance_revision(input, spaces) do
    state = input.arguments.state

    Aikido.Types.ActionResult.new(
      changes: %{
        spaces: spaces,
        rev: state.rev + 1,
        updated_at: Aikido.Signal.timestamp(get_in(input.context, [:aikido, :signal]))
      }
    )
  end

  def invalid_space_argument(input, message) do
    {:error,
     Ash.Error.Action.InvalidArgument.exception(
       field: :space,
       value: input.arguments.space,
       message: message
     )}
  end
end
