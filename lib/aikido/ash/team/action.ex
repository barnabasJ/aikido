defmodule Aikido.Ash.Team.Action do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    runtime = input.context.aikido
    resource = runtime.agent_module
    config = Aikido.Dsl.Agent.Info.team_config(resource)

    data = Map.get(input.arguments, :data, Map.delete(input.arguments, :state))
    signal = %{runtime.signal | data: Map.merge(runtime.signal.data || %{}, data)}

    case Aikido.Ash.Team.Engine.handle(signal, input.arguments.state, runtime, config) do
      {:ok, state, directives} ->
        Aikido.Types.ActionResult.new(state: state, directives: directives)

      {:error, _} = error ->
        error
    end
  end
end
