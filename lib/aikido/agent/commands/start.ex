defmodule Aikido.Agent.Commands.Start do
  @moduledoc "External Ash command boundary. Starts a durable agent through native scoped initialization and completes its initial team topology."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Agent.CommandRuntime
  alias Aikido.Agent.Errors.StartupCleanupFailed
  alias Aikido.Durable.ScopeAdapter.Error, as: ScopeRefusal

  @impl true
  def run(input, _opts, context) do
    resource = input.resource

    with {:ok, topology} <- startup_topology(resource, input.arguments[:topology]) do
      start_process(resource, input, topology, context)
    end
  end

  defp startup_topology(resource, definition) do
    if config = Aikido.Agent.Info.team_config(resource) do
      Aikido.Team.Topology.build(
        definition || config.topology.nodes,
        config.instance,
        config.max_members
      )
    else
      {:ok, nil}
    end
  end

  defp start_process(resource, input, topology, context) do
    pool = Aikido.durable_supervisor_name(Aikido.Agent.Info.agent_instance!(resource))

    runtime_options =
      input.context
      |> Map.get(:aikido_runtime_options, [])
      |> Keyword.take([:parent, :partition, :on_parent_death, :restart?, :sync])

    runtime_options =
      Keyword.put(
        runtime_options,
        :sync,
        input.arguments[:sync] || runtime_options[:sync] ||
          inherited_sync(runtime_options[:parent])
      )

    options = activation_options(resource, input, context, runtime_options)

    CommandRuntime.catch_runtime_exit(fn ->
      case Aikido.Durable.start(pool, input.arguments.id, options) do
        {:ok, pid} ->
          configure_topology_or_stop_agent(
            resource,
            input,
            context,
            topology,
            pid,
            runtime_options
          )

        {:error, {:already_started, _pid}} ->
          {:error, {:already_started, input.arguments.id}}

        {:error, {%ScopeRefusal{} = refusal, stacktrace}} when is_list(stacktrace) ->
          {:error, public_scope_refusal(refusal)}

        {:error, %ScopeRefusal{} = refusal} ->
          {:error, public_scope_refusal(refusal)}

        {:error, _} = error ->
          error
      end
    end)
  end

  defp public_scope_refusal(refusal) do
    ScopeRefusal.exception(
      operation: scope_refusal_operation(refusal.operation),
      reason: scope_refusal_reason(refusal.reason)
    )
  end

  defp scope_refusal_operation(operation) when operation in [:prepare, :restore, :checkpoint],
    do: operation

  defp scope_refusal_operation(_operation), do: :activation

  defp scope_refusal_reason(reason) when is_atom(reason), do: reason
  defp scope_refusal_reason(_reason), do: :scope_rejected

  defp inherited_sync(nil), do: %Aikido.Durable.SyncPolicy{}

  defp inherited_sync(%{pid: parent}) do
    case Aikido.AgentServer.state(parent, &{:ok, &1.sync}) do
      {:ok, sync} -> sync
      {:error, reason} -> raise "Cannot inherit parent synchronization policy: #{inspect(reason)}"
    end
  end

  defp activation_options(resource, input, context, runtime_options) do
    initialization = input |> CommandRuntime.command_context(context) |> Map.to_list()

    [
      agent: resource,
      initial_state: initial_state(resource, input.arguments),
      partition: runtime_options[:partition],
      agent_opts: Keyword.put(runtime_options, :initialization_options, initialization),
      permanent: Keyword.get(runtime_options, :restart?, true)
    ]
  end

  defp configure_topology_or_stop_agent(resource, input, context, topology, pid, runtime_options) do
    pool = Aikido.durable_supervisor_name(Aikido.Agent.Info.agent_instance!(resource))

    with {:ok, _} <-
           configure_initial_topology(resource, input, context, topology, pid, runtime_options) do
      {:ok, CommandRuntime.reference(resource, input.arguments.id, pid)}
    else
      error ->
        cleanup =
          CommandRuntime.catch_runtime_exit(fn ->
            Aikido.Durable.stop(pool, pid, scope: CommandRuntime.command_context(input, context))
          end)

        case cleanup do
          :ok ->
            error

          {:error, cleanup_error} ->
            {:error,
             StartupCleanupFailed.exception(
               agent_id: input.arguments.id,
               startup: error,
               cleanup: cleanup_error
             )}
        end
    end
  end

  defp configure_initial_topology(resource, input, context, topology, pid, runtime_options) do
    pool = Aikido.durable_supervisor_name(Aikido.Agent.Info.agent_instance!(resource))

    restored? =
      Process.whereis(pool) && Aikido.Durable.restored?(pool, input.arguments.id, runtime_options)

    if !is_nil(Aikido.Agent.Info.team_config(resource)) && !restored? do
      Aikido.Team.Extension.start(
        resource,
        pid,
        topology.nodes,
        CommandRuntime.command_context(input, context)
      )
    else
      {:ok, :ready}
    end
  end

  defp initial_state(resource, attributes) do
    {own, slices} =
      attributes |> Map.drop([:id, :sync]) |> Map.split(Aikido.Agent.Info.state_fields(resource))

    slices
    |> put_ai_configuration(own, resource)
    |> Map.put(Aikido.Agent.Info.agent_path!(resource), own)
  end

  defp put_ai_configuration(slices, own, resource) do
    if Aikido.Agent.Info.ai?(resource) do
      configuration =
        own
        |> Map.take([
          :options,
          :tools,
          :tool_options,
          :tool_context,
          :hooks,
          :model,
          :client,
          :llm_opts,
          :system_prompt,
          :max_iterations
        ])
        |> default_tool_application(resource)

      Map.put(slices, :ai, Map.merge(Map.get(slices, :ai) || %{}, configuration))
    else
      slices
    end
  end

  defp default_tool_application(configuration, resource) do
    options =
      Keyword.put_new_lazy(configuration.tool_options, :otp_app, fn ->
        Spark.otp_app(resource) || Spark.otp_app(Ash.Resource.Info.domain(resource)) || :aikido
      end)

    Map.put(configuration, :tool_options, options)
  end
end
