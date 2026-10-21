defmodule Aikido.Team.Actions.AddMember do
  @moduledoc "Adds a member from a worker template or resource and activates eager members."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, TopologyOperation, Topology}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = ActionAdapter.unpack_team_action(input)
    ActionAdapter.to_action_result(add_member_and_activate(signal, state, context, config))
  end

  defp add_member_and_activate(signal, state, context, config) do
    TopologyOperation.begin_topology_change(signal, state, context, config, fn ->
      plan_member_addition(signal.data, state, config)
    end)
  end

  defp plan_member_addition(data, state, config) do
    with {:ok, spec} <- member_spec(data, state, config),
         {:ok, next} <-
           Topology.put(
             state.topology,
             data.member,
             spec,
             config.instance,
             config.max_members
           ) do
      {:ok, next, [], if(spec.activation == :eager, do: [data.member], else: []), state.paused}
    end
  end

  defp member_spec(data, state, config) do
    template = Map.get(data, :template)

    definition =
      if template,
        do: Map.get(config.workers, template),
        else: %{resource: Map.get(data, :resource)}

    count = Enum.count(state.topology.nodes, fn {_, spec} -> spec.template == template end)

    cond do
      is_nil(definition) ->
        {:error, {:unknown_worker_template, template}}

      template && count >= definition.max_members ->
        {:error, {:worker_limit, template}}

      true ->
        {:ok,
         %{
           resource: definition.resource,
           template: template,
           initial_state:
             DeepMerge.deep_merge(
               Map.get(definition, :initial_state, %{}),
               Map.get(data, :initial_state, %{})
             ),
           owner: Map.get(data, :owner),
           depends_on: Map.get(data, :depends_on, []),
           activation: Map.get(data, :activation, :eager)
         }}
    end
  end
end
