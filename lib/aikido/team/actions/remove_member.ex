defmodule Aikido.Team.Actions.RemoveMember do
  @moduledoc "Removes a member and optional dependents from the desired topology and stops them."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{Inputs, Operation, Topology}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.read(input)
    Inputs.result(remove_member_and_dependents(signal, state, context, config))
  end

  defp remove_member_and_dependents(signal, state, context, config) do
    Operation.start(signal, state, context, config, fn ->
      plan_member_removal(signal.data, state, config)
    end)
  end

  defp plan_member_removal(data, state, _config) do
    with {:ok, next, removed} <-
           Topology.remove(state.topology, data.member, Map.get(data, :cascade?, false)) do
      {:ok, next, removed, [], Map.drop(state.paused, removed)}
    end
  end
end
