defmodule Aikido.Agent.Commands.Stop do
  @moduledoc "External Ash command boundary. Stops a live durable agent and returns its identity and stopped status."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Agent.CommandRuntime

  @impl true
  def run(input, _opts, context) do
    resource = input.resource
    agent = input.arguments.agent

    CommandRuntime.catch_runtime_exit(fn ->
      with {:ok, {id, pid}} <- CommandRuntime.resolve(resource, agent),
           :ok <-
             Aikido.Durable.stop(
               Aikido.durable_supervisor_name(Aikido.Agent.Info.agent_instance!(resource)),
               pid,
               scope: CommandRuntime.command_context(input, context)
             ) do
        {:ok, %{id: id, resource: resource, status: :stopped}}
      end
    end)
  end
end
