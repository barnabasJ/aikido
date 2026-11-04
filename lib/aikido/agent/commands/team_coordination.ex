defmodule Aikido.Agent.Commands.TeamCoordination do
  @moduledoc "Native public command reading a finite Team view under ordinary Ash policies."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Agent.CommandRuntime

  @impl true
  def run(input, _options, context) do
    CommandRuntime.catch_runtime_exit(fn ->
      with {:ok, {_id, pid}} <- CommandRuntime.resolve(input) do
        Aikido.AgentServer.state(pid, fn runtime ->
          if runtime.agent_module == input.resource do
            current_input =
              Ash.ActionInput.set_context(input, %{
                aikido: Aikido.Team.MemberIdentity.coordinator_context(runtime, pid)
              })

            with :ok <- CommandRuntime.authorize_resolved(current_input, context, pid) do
              Aikido.Team.Coordination.project(runtime, input.arguments.requester)
            end
          else
            {:error, Ash.Error.Forbidden.exception([])}
          end
        end)
      end
    end)
  end
end
