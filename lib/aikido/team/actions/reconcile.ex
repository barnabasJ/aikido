defmodule Aikido.Team.Actions.Reconcile do
  @moduledoc "Restarts requested members and activates eager members while respecting paused members."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{Inputs, Operation, Topology}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.read(input)
    Inputs.result(reduce(signal, state, context, config))
  end

  defp reduce(signal, state, context, config) do
    Operation.start(signal, state, context, config, fn ->
      plan(signal.data, state, config)
    end)
  end

  defp plan(data, state, _config) do
    requested = Enum.uniq(Topology.eager(state.topology) ++ Map.get(data, :members, []))

    {:ok, state.topology, Map.get(data, :replace, []),
     Enum.reject(requested, &Map.has_key?(state.paused, &1)), state.paused}
  end
end
