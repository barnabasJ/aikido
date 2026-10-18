defmodule Aikido.Slices.ChildBus.AutoSubscribeChild.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  require Logger
  @impl true
  def run(input, _opts, _context) do
    params = Map.delete(input.arguments, :state)
    slice = input.arguments.state

    with {:ok, bus} <- fetch_bus(slice),
         {:ok, routes} <- fetch_routes(params.child_module) do
      directives =
        Enum.map(routes, fn route ->
          %Aikido.Slices.ChildBus.Directives.SubscribeChild{
            bus: bus,
            tag: params.tag,
            path: elem(route, 0),
            target_pid: params.pid,
            child_module: params.child_module
          }
        end)

      Aikido.ActionResult.new(state: slice, directives: directives)
    else
      {:error, reason} ->
        Logger.warning("child_bus: skipped auto-subscribe — #{reason}")
        Aikido.ActionResult.new(state: slice, directives: [])
    end
  end

  defp fetch_bus(slice) do
    case Map.get(slice, :bus) do
      bus when is_atom(bus) and not is_nil(bus) -> {:ok, bus}
      _ -> {:error, "no :bus configured under :child_bus slice"}
    end
  end

  defp fetch_routes(child_module) do
    if Spark.Dsl.is?(child_module, Aikido.Slice) do
      {:ok, Aikido.Dsl.Slice.Info.signal_routes(child_module)}
    else
      {:error, "#{inspect(child_module)} is not a Aikido.Slice"}
    end
  end
end
