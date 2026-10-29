defmodule Aikido.Agent.CommandRuntime do
  @moduledoc """
  Shared runtime access for external domain commands.

  Resolves agent references, reads live snapshots, forwards caller scope and
  translates process exits at the public command boundary. These helpers may
  perform runtime I/O and are separate from pure agent and slice reducers.
  """
  alias Aikido.Agent.Errors.RuntimeUnavailable
  alias Aikido.AgentServer

  def command_context(input, context) do
    application_context = Map.drop(input.context, [:private, :aikido_runtime_options, :aikido])

    context
    |> Ash.Scope.to_opts(context: application_context)
    |> Map.new()
  end

  def reference(resource, id, pid), do: %{id: id, pid: pid, resource: resource}

  def resolve(resource, %{id: id}), do: resolve(resource, id)

  def resolve(resource, id) when is_binary(id) do
    case Aikido.Durable.lookup(
           Aikido.durable_supervisor_name(Aikido.Agent.Info.agent_instance!(resource)),
           id
         ) do
      :error -> {:error, RuntimeUnavailable.exception(reason: :not_running)}
      {:ok, pid} -> resolve(resource, pid)
    end
  end

  def resolve(resource, pid) when is_pid(pid) do
    AgentServer.state(pid, fn state ->
      if state.agent.agent_module == resource,
        do: {:ok, {state.agent.id, pid}},
        else: {:error, :different_resource}
    end)
  end

  def resolve(_resource, _), do: {:error, "Expected an agent ID, PID, or reference"}

  def snapshot(resource, pid, options \\ []) do
    with {:ok, attributes} <-
           AgentServer.state(pid, fn state ->
             if state.agent.agent_module == resource do
               {:ok, Aikido.Agent.resource_attributes(state.agent)}
             else
               {:error, :different_resource}
             end
           end) do
      # Inspect/list already authorize the caller. This internal action only casts
      # their read projection; it must not introduce another authorization policy.
      projection_options = Keyword.put(options, :authorize?, false)

      resource
      |> Ash.ActionInput.for_action(
        :__aikido_snapshot__,
        %{snapshot: attributes},
        projection_options
      )
      |> Ash.run_action(projection_options)
    end
  end

  @doc "Translate runtime process exits into the public tagged error contract."
  def catch_runtime_exit(fun) do
    fun.()
  catch
    :exit, reason -> {:error, RuntimeUnavailable.exception(reason: reason)}
  end
end
