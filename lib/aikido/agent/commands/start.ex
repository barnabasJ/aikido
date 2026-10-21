defmodule Aikido.Agent.Commands.Start do
  @moduledoc "External Ash command boundary. Starts a durable agent through native scoped initialization and completes its initial team topology."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Agent.Runtime

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
    id = input.arguments.id

    runtime_options =
      input.context
      |> Map.get(:aikido_runtime_options, [])
      |> Keyword.take([:parent, :partition, :on_parent_death, :restart?])

    pool = Aikido.durable_supervisor_name(Aikido.Agent.Info.agent_instance!(resource))

    Runtime.safe(fn ->
      with {:ok, pid} <-
             Aikido.Durable.start(pool, id,
               agent: resource,
               initial_state: initial_state(resource, input.arguments),
               partition: runtime_options[:partition],
               agent_opts:
                 Keyword.put(
                   runtime_options,
                   :initialization_options,
                   Runtime.command_context(input, context) |> Map.to_list()
                 ),
               permanent: Keyword.get(runtime_options, :restart?, true)
             ) do
        restored? =
          Process.whereis(pool) && Aikido.Durable.restored?(pool, id, runtime_options)

        result =
          if !is_nil(Aikido.Agent.Info.team_config(resource)) && !restored?,
            do:
              Aikido.Team.Extension.start(
                resource,
                pid,
                topology.nodes,
                Runtime.command_context(input, context)
              ),
            else: {:ok, :ready}

        case result do
          {:ok, _} ->
            {:ok, Runtime.reference(resource, id, pid)}

          error ->
            Aikido.Durable.stop(
              Aikido.durable_supervisor_name(Aikido.Agent.Info.agent_instance!(resource)),
              pid
            )

            error
        end
      end
    end)
  end

  defp initial_state(resource, attributes) do
    attributes
    |> Map.delete(:id)
    |> then(fn attributes ->
      {own_state, slices} = Map.split(attributes, Aikido.Agent.Info.state_fields(resource))

      slices =
        if Aikido.Agent.Info.ai?(resource) do
          configuration =
            Map.take(own_state, [
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

          tool_options =
            Keyword.put_new_lazy(configuration.tool_options, :otp_app, fn ->
              Spark.otp_app(resource) || Spark.otp_app(Ash.Resource.Info.domain(resource)) ||
                :aikido
            end)

          configuration = Map.put(configuration, :tool_options, tool_options)
          Map.put(slices, :ai, Map.merge(Map.get(slices, :ai) || %{}, configuration))
        else
          slices
        end

      Map.put(slices, Aikido.Agent.Info.agent_path!(resource), own_state)
    end)
  end
end
