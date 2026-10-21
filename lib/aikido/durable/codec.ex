defmodule Aikido.Durable.Codec do
  @moduledoc """
  Optional serialization callbacks for agent and slice state in DurableServer snapshots.

  `externalize/1` receives the value at the agent's own state path or the slice's
  mount path. `reinstate/1` reconstructs that value on activation. Modules without
  these callbacks retain their state unchanged. Both callbacks must be provided
  together, and the stored value must contain everything needed for restoration.

  Agent-wide snapshot customization uses `c:Aikido.Agent.checkpoint/2` and
  `c:Aikido.Agent.restore/2`. Path codecs run before checkpoint and after restore.
  """

  @callback externalize(term()) :: term()
  @callback reinstate(term()) :: term()

  @doc false
  def transform_agent(agent, agent_module, callback)
      when callback in [:externalize, :reinstate] do
    mounts =
      agent_module
      |> Aikido.Agent.Info.slice_instances()
      |> Enum.map(&{&1.module, &1.path})

    own =
      case Spark.Dsl.Extension.get_opt(agent_module, [:agent], :path) do
        nil -> []
        path -> [{agent_module, path}]
      end

    state =
      Enum.reduce(own ++ mounts, agent.state, fn {module, path}, state ->
        if Map.has_key?(state, path) && Code.ensure_loaded?(module) &&
             function_exported?(module, :externalize, 1) &&
             function_exported?(module, :reinstate, 1) do
          Map.update!(state, path, &apply(module, callback, [&1]))
        else
          state
        end
      end)

    %{agent | state: state}
  end
end
