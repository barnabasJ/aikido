defmodule Aikido.Agent.Commands.Delete do
  @moduledoc "External Ash command boundary. Deletes a live or stopped durable identity while preserving native resource and partition checks."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Agent.CommandRuntime

  @impl true
  def run(input, _opts, _context) do
    resource = input.resource
    agent = input.arguments.agent

    CommandRuntime.catch_runtime_exit(fn ->
      with {:ok, {id, target}} <- resolve_deletion_target(input, agent),
           :ok <- delete_durable_identity(input, target) do
        {:ok, %{id: id, resource: resource, status: :deleted}}
      end
    end)
  end

  defp resolve_deletion_target(input, pid) when is_pid(pid) do
    with {:ok, {id, _pid}} <- CommandRuntime.resolve(input, pid), do: {:ok, {id, pid}}
  end

  defp resolve_deletion_target(input, %{id: id}), do: resolve_deletion_target(input, id)
  defp resolve_deletion_target(_input, id) when is_binary(id), do: {:ok, {id, id}}

  defp resolve_deletion_target(_input, _),
    do: {:error, "Expected an agent ID, PID, or reference"}

  defp delete_durable_identity(input, pid) when is_pid(pid) do
    with {:ok, {pool, key, partition}} <-
           Aikido.AgentServer.state(pid, fn runtime ->
             {:ok, {runtime.durable_server, runtime.durable_key, runtime.partition}}
           end) do
      Aikido.Durable.delete(pool, key,
        agent: input.resource,
        partition: partition
      )
    end
  end

  defp delete_durable_identity(input, id) do
    instance = CommandRuntime.instance(input)
    pool = Aikido.durable_supervisor_name(instance)

    Aikido.Durable.delete(pool, id, agent: input.resource)
  end
end
