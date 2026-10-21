defmodule Aikido.Team.Actions.StopMember do
  @moduledoc "Stops a member and its descendants while retaining their paused topology entries."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{Inputs, Operation, Topology}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.read(input)
    Inputs.result(pause_member_and_descendants(signal, state, context, config))
  end

  defp pause_member_and_descendants(signal, state, context, config) do
    Operation.start(signal, state, context, config, fn ->
      plan_member_stop(signal.data, state, config)
    end)
  end

  defp plan_member_stop(data, state, _config) do
    with {:ok, _next, stopped} <- Topology.remove(state.topology, data.member, true) do
      {:ok, state.topology, stopped, [], Map.merge(state.paused, Map.new(stopped, &{&1, true}))}
    end
  end
end
