defmodule Aikido.Team.ActionAdapter do
  @moduledoc """
  Adapts native Ash team actions to the shared topology and task transition functions.

  Input extraction keeps the signal payload, team state, caller context and
  configuration together. Result conversion preserves transition errors and
  returns only changed team attributes with the transition's directives.
  """

  @doc "Return the payload-enriched signal, team state, runtime context and team configuration."
  def unpack_team_action(input) do
    runtime = input.context.aikido
    config = Aikido.Agent.Info.team_config(runtime.agent_module)
    data = Map.get(input.arguments, :data, Map.delete(input.arguments, :state))
    signal = %{runtime.signal | data: Map.merge(runtime.signal.data || %{}, data)}
    {signal, input.arguments.state, runtime, config}
  end

  @doc "Compare a team transition with its input and return changed attributes, preserving errors."
  def to_action_result({:ok, state, directives}, previous) do
    attributes = Enum.map(Ash.Resource.Info.attributes(Aikido.Team.Slice), & &1.name)

    changes =
      state
      |> Map.take(attributes)
      |> Map.reject(fn {name, value} -> Map.get(previous, name) == value end)

    Aikido.Types.ActionResult.new(
      changes: if(map_size(changes) == 0, do: nil, else: changes),
      directives: directives
    )
  end

  def to_action_result({:error, _} = error, _previous), do: error
end
