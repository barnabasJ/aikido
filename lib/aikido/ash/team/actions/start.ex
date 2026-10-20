defmodule Aikido.Ash.Team.Actions.Start do
  @moduledoc "Builds the desired team topology and begins ordered member activation."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Ash.Team.{Inputs, Operation, Topology}

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

  defp plan(data, state, config) do
    with {:ok, next} <-
           Topology.build(
             data[:topology] || state.topology.nodes,
             config.instance,
             config.max_members
           ) do
      changed =
        for {name, spec} <- state.topology.nodes, Map.get(next.nodes, name) != spec, do: name

      affected = Topology.affected(state.topology, changed)

      retained =
        Enum.filter(
          affected,
          &(Map.has_key?(state.members, &1) && Map.has_key?(next.nodes, &1))
        )

      {:ok, next, affected, Enum.uniq(Topology.eager(next) ++ retained), %{}}
    end
  end
end
