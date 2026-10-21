defmodule Aikido.Agent.Commands.Delete do
  @moduledoc "External Ash command boundary. Deletes a live or stopped durable identity while preserving native resource and partition checks."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Agent.Runtime

  @impl true
  def run(input, _opts, _context) do
    resource = input.resource
    agent = input.arguments.agent

    Runtime.catch_runtime_exit(fn ->
      with {:ok, {id, target}} <- resolve_deletion_target(resource, agent),
           :ok <- delete_durable_identity(resource, target) do
        {:ok, %{id: id, resource: resource, status: :deleted}}
      end
    end)
  end

  defp resolve_deletion_target(resource, pid) when is_pid(pid) do
    with {:ok, {id, _pid}} <- Runtime.resolve(resource, pid), do: {:ok, {id, pid}}
  end

  defp resolve_deletion_target(resource, %{id: id}), do: resolve_deletion_target(resource, id)
  defp resolve_deletion_target(_resource, id) when is_binary(id), do: {:ok, {id, id}}

  defp resolve_deletion_target(_resource, _),
    do: {:error, "Expected an agent ID, PID, or reference"}

  defp delete_durable_identity(resource, pid) when is_pid(pid) do
    with {:ok, {pool, key, partition}} <-
           Aikido.AgentServer.state(pid, fn runtime ->
             {:ok, {runtime.durable_server, runtime.durable_key, runtime.partition}}
           end) do
      Aikido.Durable.delete(pool, key,
        agent: resource,
        partition: partition
      )
    end
  end

  defp delete_durable_identity(resource, id) do
    instance = Aikido.Agent.Info.agent_instance!(resource)
    pool = Aikido.durable_supervisor_name(instance)

    Aikido.Durable.delete(pool, id, agent: resource)
  end
end
