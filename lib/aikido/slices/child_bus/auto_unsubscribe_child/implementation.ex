defmodule Aikido.Slices.ChildBus.AutoUnsubscribeChild.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  require Logger
  @impl true
  def run(input, _opts, _context) do
    tag = input.arguments[:tag]
    slice = input.arguments.state

    with {:ok, bus} <- fetch_bus(slice),
         sub_ids when is_list(sub_ids) <- get_in(slice, [:subscriptions, tag]) do
      directives =
        Enum.map(
          sub_ids,
          &%Aikido.Slices.ChildBus.Directives.UnsubscribeChild{bus: bus, sub_id: &1, tag: tag}
        )

      subscriptions = Map.delete(Map.get(slice, :subscriptions, %{}), tag)

      Aikido.ActionResult.new(
        state: Map.put(slice, :subscriptions, subscriptions),
        directives: directives
      )
    else
      _ ->
        Logger.debug("child_bus: no subscriptions tracked for #{inspect(tag)}, skipping")
        Aikido.ActionResult.new(state: slice, directives: [])
    end
  end

  defp fetch_bus(slice) do
    case Map.get(slice, :bus) do
      bus when is_atom(bus) and not is_nil(bus) -> {:ok, bus}
      _ -> {:error, :no_bus}
    end
  end
end
