defmodule Aikido.Ash.Actions.Stop do
  @moduledoc "Stops a live durable agent and returns its identity and stopped status."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Ash.Runtime

  @impl true
  def run(input, _opts, _context) do
    resource = input.resource
    agent = input.arguments.agent

    Runtime.safe(fn ->
      with {:ok, {id, pid}} <- Runtime.resolve(resource, agent),
           :ok <-
             Aikido.Durable.stop(
               Aikido.durable_supervisor_name(Aikido.Dsl.Agent.Info.agent_instance!(resource)),
               pid
             ) do
        {:ok, %{id: id, resource: resource, status: :stopped}}
      end
    end)
  end
end
