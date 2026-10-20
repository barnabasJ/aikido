defmodule Aikido.Ash.Actions.Delete do
  @moduledoc "Deletes a live or stopped durable identity while preserving native resource and partition checks."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Ash.Runtime

  @impl true
  def run(input, _opts, _context) do
    resource = input.resource
    agent = input.arguments.agent

    Runtime.safe(fn ->
      with {:ok, {id, target}} <- deletion_id(resource, agent),
           :ok <- delete_process(resource, target) do
        {:ok, %{id: id, resource: resource, status: :deleted}}
      end
    end)
  end

  defp deletion_id(resource, pid) when is_pid(pid) do
    with {:ok, {id, _pid}} <- Runtime.resolve(resource, pid), do: {:ok, {id, pid}}
  end

  defp deletion_id(resource, %{id: id}), do: deletion_id(resource, id)
  defp deletion_id(_resource, id) when is_binary(id), do: {:ok, {id, id}}
  defp deletion_id(_resource, _), do: {:error, "Expected an agent ID, PID, or reference"}

  defp delete_process(resource, pid) when is_pid(pid) do
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

  defp delete_process(resource, id) do
    instance = Aikido.Dsl.Agent.Info.agent_instance!(resource)
    pool = Aikido.durable_supervisor_name(instance)

    Aikido.Durable.delete(pool, id, agent: resource)
  end
end
