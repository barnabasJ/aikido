defmodule Aikido.Ash.Team.Inputs do
  @moduledoc false

  def read(input) do
    runtime = input.context.aikido
    config = Aikido.Ash.Agent.Info.team_config(runtime.agent_module)
    data = Map.get(input.arguments, :data, Map.delete(input.arguments, :state))
    signal = %{runtime.signal | data: Map.merge(runtime.signal.data || %{}, data)}
    {signal, input.arguments.state, runtime, config}
  end

  def result({:ok, state, directives}),
    do: Aikido.Types.ActionResult.new(state: state, directives: directives)

  def result({:error, _} = error), do: error
end
