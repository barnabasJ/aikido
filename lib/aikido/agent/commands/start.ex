defmodule Aikido.Agent.Commands.Start do
  @moduledoc "External Ash command boundary. Starts a durable agent through native scoped initialization and completes its initial team topology."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Agent.CommandRuntime

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
      |> Keyword.take([:parent, :partition, :on_parent_death, :restart?])

    options = activation_options(resource, input, context, runtime_options)

    CommandRuntime.catch_runtime_exit(fn ->
      with {:ok, pid} <- Aikido.Durable.start(pool, input.arguments.id, options) do
        configure_topology_or_stop_agent(resource, input, context, topology, pid, runtime_options)
      end
    end)
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
        Aikido.Durable.stop(pool, pid)
        error
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
      attributes |> Map.delete(:id) |> Map.split(Aikido.Agent.Info.state_fields(resource))

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
