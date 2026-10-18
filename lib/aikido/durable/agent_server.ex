defmodule Aikido.Durable.AgentServer do
  @moduledoc false
  use DurableServer, vsn: 1
  alias Aikido.AgentServer
  alias Aikido.Middlewares.Persister

  @impl true
  def dump_state(%{runtime: runtime} = state) do
    agent = %{runtime.agent | state: durable_domain_state(runtime.agent.state)}
    agent = Persister.transform_agent(agent, runtime.agent_module, :externalize)

    encode(%{
      options: state.options,
      permanent: state.permanent,
      agent: serialize_agent(agent, runtime.agent_module),
      cron_specs: runtime.cron_specs
    })
  end

  def dump_state(initial), do: encode(initial)

  @impl true
  def load_state(version, %{"payload" => payload}) when version in [nil, 1],
    do: payload |> Base.decode64!() |> :erlang.binary_to_term([:safe])

  @impl true
  def init(saved) do
    options = restore_parent(saved.options)

    options =
      if saved[:agent],
        do:
          Keyword.put(
            options,
            :restored_agent,
            restore_agent(saved.agent, options[:agent_module])
          ),
        else: options

    options = Keyword.put(options, :restored_cron_specs, Map.get(saved, :cron_specs, %{}))

    case AgentServer.init(options) do
      {:ok, runtime, {:continue, continue}} ->
        send(self(), {:aikido_durable_continue, continue, Map.has_key?(saved, :agent)})

        {:ok, %{runtime: runtime, options: saved.options, permanent: saved.permanent},
         permanent: saved.permanent,
         meta: %{
           key: runtime.lifecycle.pool_key,
           partition: runtime.partition,
           restored?: Map.has_key?(saved, :agent)
         }}

      {:stop, reason} ->
        raise "Cannot initialize durable agent: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_call(request, from, state),
    do: wrap(AgentServer.handle_call(request, from, state.runtime), state)

  @impl true
  def handle_cast(request, state),
    do: wrap(AgentServer.handle_cast(request, state.runtime), state)

  @impl true
  def handle_info({:aikido_durable_continue, continue, restored?}, state) do
    result = AgentServer.handle_continue(continue, state.runtime)
    if restored?, do: maybe_reconcile(state.runtime)
    wrap(result, state)
  end

  def handle_info(message, state),
    do: wrap(AgentServer.handle_info(message, state.runtime), state)

  @impl true
  def handle_continue(continue, state),
    do: wrap(AgentServer.handle_continue(continue, state.runtime), state)

  @impl true
  def terminate(reason, state), do: AgentServer.terminate(reason, state.runtime)

  defp wrap({:reply, reply, runtime}, state),
    do: {:reply, reply, %{state | runtime: runtime}, sync: true}

  defp wrap({:noreply, runtime}, state), do: {:noreply, %{state | runtime: runtime}, sync: true}

  defp wrap({:stop, reason, runtime}, state),
    do: {:stop, stop_reason(reason), %{state | runtime: runtime}}

  defp wrap({:stop, reason, reply, runtime}, state),
    do: {:stop, stop_reason(reason), reply, %{state | runtime: runtime}}

  defp stop_reason(:normal), do: :permanent
  defp stop_reason(:shutdown), do: {:shutdown, :permanent}
  defp stop_reason({:shutdown, _}), do: {:shutdown, :permanent}
  defp stop_reason(reason), do: {:error, reason}

  defp encode(data),
    do: %{"payload" => Base.encode64(:erlang.term_to_binary(data, [:compressed]))}

  # Process references from an earlier incarnation never establish ownership.
  # Resolve the saved logical parent against the current runtime first.
  defp restore_parent(options) do
    case options[:parent] do
      %{id: id} = parent ->
        pid = Aikido.whereis(options[:aikido], id, partition: Map.get(parent, :partition))
        pid = pid || live_pid(Map.get(parent, :pid))

        if pid do
          meta = Map.get(parent, :meta, %{})

          meta =
            if meta[:team_id],
              do: Map.put(meta, :team_pid, Aikido.whereis(options[:aikido], meta.team_id)),
              else: meta

          Keyword.put(options, :parent, parent |> Map.put(:pid, pid) |> Map.put(:meta, meta))
        else
          Keyword.delete(options, :parent)
        end

      _ ->
        options
    end
  end

  defp live_pid(pid) when is_pid(pid) and node(pid) == node(),
    do: if(Process.alive?(pid), do: pid)

  defp live_pid(_), do: nil

  defp serialize_agent(agent, runtime_module) do
    module = Persister.callback_module(runtime_module)

    if function_exported?(module, :checkpoint, 2) do
      case module.checkpoint(agent, %{}) do
        {:ok, checkpoint} when is_map(checkpoint) ->
          {:checkpoint, checkpoint}

        other ->
          raise ArgumentError, "Invalid checkpoint from #{inspect(module)}: #{inspect(other)}"
      end
    else
      if function_exported?(module, :restore, 2),
        do:
          {:checkpoint,
           %{
             version: 1,
             agent_module: runtime_module,
             id: agent.id,
             state: agent.state,
             thread: nil
           }},
        else: {:agent, agent}
    end
  end

  defp restore_agent({:checkpoint, checkpoint}, runtime_module) do
    module = Persister.callback_module(runtime_module)

    case module.restore(checkpoint, %{}) do
      {:ok, %Aikido.Agent{} = agent} ->
        Persister.transform_agent(agent, runtime_module, :reinstate)

      other ->
        raise ArgumentError, "Invalid restoration from #{inspect(module)}: #{inspect(other)}"
    end
  end

  defp restore_agent({:agent, agent}, runtime_module),
    do: Persister.transform_agent(agent, runtime_module, :reinstate)

  defp durable_domain_state(state) do
    case state[:team] do
      %Aikido.Ash.Team.State{} = team ->
        Map.put(state, :team, %{
          team
          | members: %{},
            incarnations: %{},
            operation: %Aikido.Ash.Team.State{}.operation
        })

      _ ->
        state
    end
  end

  defp maybe_reconcile(runtime) do
    if function_exported?(runtime.agent_module, :__aikido_resource__, 0) &&
         function_exported?(
           runtime.agent_module.__aikido_resource__(),
           :__aikido_team_config__,
           0
         ) do
      send(self(), {:signal, Jido.Signal.new!("aikido.ash.team.reconcile", %{})})
    end
  end
end
