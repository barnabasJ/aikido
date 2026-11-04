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

  def instance(input) do
    instance_override(input) || configured_instance(input.resource)
  end

  defp configured_instance(resource) do
    declared = Aikido.Agent.Info.agent_instance!(resource)

    if Spark.Dsl.is?(declared, Aikido.Instance.Host),
      do: Aikido.config(declared)[:name],
      else: declared
  end

  defp instance_override(input), do: input.context[:aikido_runtime_options][:instance]

  def resolve(input), do: resolve(input, input.arguments.agent)

  def resolve(resource, target) when is_atom(resource) do
    resolve(%{resource: resource, context: %{}}, target)
  end

  def resolve(input, %{pid: pid}) when is_pid(pid), do: resolve(input, pid)
  def resolve(input, %{id: id}), do: resolve(input, id)

  def resolve(input, id) when is_binary(id) do
    case Aikido.Durable.lookup(Aikido.durable_supervisor_name(instance(input)), id) do
      :error -> {:error, RuntimeUnavailable.exception(reason: :not_running)}
      {:ok, pid} -> resolve(input, pid)
    end
  end

  def resolve(input, pid) when is_pid(pid) do
    selected = instance_override(input)

    AgentServer.state(pid, fn state ->
      cond do
        state.agent.agent_module != input.resource -> {:error, :different_resource}
        selected && state.aikido != selected -> {:error, :different_instance}
        true -> {:ok, {state.agent.id, pid}}
      end
    end)
  end

  def resolve(_input, _), do: {:error, "Expected an agent ID, PID, or reference"}

  @doc "Authorize the same public command against its exact resolved process before I/O."
  def authorize_resolved(input, context, pid) when is_pid(pid) do
    options = Ash.Scope.to_opts(context, context: input.context)

    if Keyword.get(options, :authorize?) == false do
      :ok
    else
      pinned =
        Ash.ActionInput.for_action(
          input.resource,
          input.action.name,
          Map.put(input.arguments, :agent, pid),
          options
        )

      case Ash.can(pinned, Keyword.get(options, :actor),
             scope: context,
             context: input.context,
             maybe_is: false,
             pre_flight?: false,
             validate?: true,
             return_forbidden_error?: true
           ) do
        {:ok, true} -> :ok
        {:ok, false, error} -> {:error, Ash.Error.to_error_class(error)}
        {:error, error} -> {:error, Ash.Error.to_error_class(error)}
        {:ok, false} -> {:error, Ash.Error.Forbidden.exception([])}
      end
    end
  end

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
