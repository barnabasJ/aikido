defmodule Aikido.Team.Inputs do
  @moduledoc "Extract native team action inputs and construct reducer results."

  @doc "Return the payload-enriched signal, team state, runtime context and team configuration."
  def unpack_team_action(input) do
    runtime = input.context.aikido
    config = Aikido.Agent.Info.team_config(runtime.agent_module)
    data = Map.get(input.arguments, :data, Map.delete(input.arguments, :state))
    signal = %{runtime.signal | data: Map.merge(runtime.signal.data || %{}, data)}
    {signal, input.arguments.state, runtime, config}
  end

  @doc "Convert a team transition into a typed action result, preserving errors."
  def to_action_result({:ok, state, directives}),
    do: Aikido.Types.ActionResult.new(state: state, directives: directives)

  def to_action_result({:error, _} = error), do: error
end
