defmodule Aikido.Ash.Team.Action do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    runtime = input.context.aikido
    resource = runtime.agent_module
    config = Aikido.Dsl.Agent.Info.team_config(resource)

    case Aikido.Ash.Team.Engine.handle(runtime.signal, input.arguments.state, runtime, config) do
      {:ok, state, directives} ->
        Aikido.Types.ActionResult.new(state: state, directives: directives)

      {:error, _} = error ->
        error
    end
  end
end
