defmodule Aikido.Ash.Team.Actions.EnsureMember do
  @moduledoc "Activates a known member and its prerequisites, clearing its intentional pause."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Ash.Team.{Inputs, Operation}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.read(input)
    Inputs.result(reduce(signal, state, context, config))
  end

  def reduce(signal, state, context, config) do
    Operation.start(signal, state, context, config, fn ->
      plan(signal.data, state, config)
    end)
  end

  defp plan(data, state, _config) do
    if Map.has_key?(state.topology.nodes, data.member),
      do: {:ok, state.topology, [], [data.member], Map.delete(state.paused, data.member)},
      else: {:error, {:unknown_member, data.member}}
  end
end
