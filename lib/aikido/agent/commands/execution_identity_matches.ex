defmodule Aikido.Agent.Commands.ExecutionIdentityMatches do
  @moduledoc "Checks the caller against immutable activation authority without returning private scope."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Agent.{CommandRuntime, ExecutionIdentity}

  @impl true
  def run(input, _options, context) do
    scope = CommandRuntime.command_context(input, context)

    CommandRuntime.catch_runtime_exit(fn ->
      with {:ok, {_id, pid}} <- CommandRuntime.resolve(input.resource, input.arguments.agent) do
        Aikido.AgentServer.state(pid, fn runtime ->
          {:ok, ExecutionIdentity.matches?(runtime.bound_execution_scope, scope)}
        end)
      end
    end)
  end
end
