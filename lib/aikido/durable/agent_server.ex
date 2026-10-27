defmodule Aikido.Durable.AgentServer do
  @moduledoc false
  use DurableServer, vsn: 2
  alias Aikido.AgentServer

  @impl true
  def dump_state(%{runtime: runtime} = state) do
    agent =
      Aikido.Durable.Codec.transform_agent(runtime.agent, runtime.agent_module, :externalize)

    encode(%{
      options: Aikido.Durable.Snapshot.boot_options(state.options),
      parent: parent_binding(Aikido.Ownership.parent(runtime)) || state[:unresolved_parent],
      permanent: state.permanent,
      agent: serialize_agent(agent, runtime.agent_module)
    })
  end

  # DurableServer re-dumps a loaded envelope while claiming its initialization
  # lock, before init/1 has reconstructed the runtime. Its codecs already ran.
  def dump_state(%{agent: _, options: _, permanent: _} = saved), do: encode(saved)

  def dump_state(%{options: options} = initial) do
    module = Keyword.fetch!(options, :agent_module)
    Code.ensure_loaded!(module)

    initialization_options = Keyword.get(options, :initialization_options, [])

    agent =
      module
      |> Ash.ActionInput.for_action(
        :initialize,
        %{id: Keyword.fetch!(options, :id), state: options[:initial_state] || %{}},
        initialization_options
      )
      |> Ash.run_action!(initialization_options)

    agent = Aikido.Durable.Codec.transform_agent(agent, module, :externalize)

    encode(%{
      options: Aikido.Durable.Snapshot.boot_options(options),
      parent: parent_binding(options[:parent]),
      permanent: initial.permanent,
      agent: serialize_agent(agent, module),
      initial?: true
    })
  end

  @impl true
  def load_state(version, envelope) when version in [nil, 1, 2],
    do: Aikido.Durable.Snapshot.load(envelope)

  @impl true
  def init(saved) do
    saved_parent = Map.get(saved, :parent, saved.options[:parent])

    options =
      saved.options
      |> Keyword.put(:parent, saved_parent)
      |> restore_parent()

    unresolved_parent =
      if saved_parent && is_nil(options[:parent]) &&
           options[:on_parent_death] not in [:continue, :emit_orphan],
         do: saved_parent

    options =
      if saved[:agent],
        do:
          Keyword.put(
            options,
            :restored_agent,
            saved.agent
            |> restore_agent(options[:agent_module])
            |> restore_mounted_slices(options[:agent_module])
            |> restore_cron_mount(options[:agent_module], Map.get(saved, :cron_specs, %{}))
          ),
        else: options

    case AgentServer.init(options) do
      {:ok, runtime, {:continue, continue}} ->
        send(
          self(),
          {:aikido_durable_continue, continue,
           Map.has_key?(saved, :agent) && !Map.get(saved, :initial?, false)}
        )

        if unresolved_parent, do: send(self(), :aikido_missing_parent)

        {:ok,
         %{
           runtime: runtime,
           options: saved.options,
           permanent: saved.permanent,
           unresolved_parent: unresolved_parent
         },
         permanent: saved.permanent,
         auto_sync: runtime.sync.mode == :automatic,
         sync_every_ms: runtime.sync.interval_ms,
         meta: %{
           key: runtime.durable_key,
           partition: runtime.partition,
           restored?: Map.has_key?(saved, :agent) && !Map.get(saved, :initial?, false)
         }}

      {:stop, reason} ->
        raise "Cannot initialize durable agent: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_call(request, from, state),
    do: wrap_runtime_reply(AgentServer.handle_call(request, from, state.runtime), state)

  @impl true
  def handle_cast({:signal, %Aikido.Signal{type: "ai.react.stream"}} = request, state) do
    # Streaming text is transient; the completed turn commits canonical history.
    wrap_runtime_reply(AgentServer.handle_cast(request, state.runtime), state, false)
  end

  def handle_cast(request, state),
    do: wrap_runtime_reply(AgentServer.handle_cast(request, state.runtime), state)

  @impl true
  def handle_info({:aikido_durable_continue, continue, restored?}, state) do
    result = AgentServer.handle_continue(continue, state.runtime)
    if restored?, do: enqueue_team_reconciliation(state.runtime)
    wrap_runtime_reply(result, state)
  end

  def handle_info(:aikido_missing_parent, %{unresolved_parent: parent} = state)
      when not is_nil(parent) do
    if is_nil(Aikido.Ownership.parent(state.runtime)) do
      wrap_runtime_reply({:stop, {:shutdown, {:parent_down, :noproc}}, state.runtime}, state)
    else
      {:noreply, %{state | unresolved_parent: nil}}
    end
  end

  def handle_info(message, state),
    do: wrap_runtime_reply(AgentServer.handle_info(message, state.runtime), state)

  @impl true
  def handle_continue(continue, state),
    do: wrap_runtime_reply(AgentServer.handle_continue(continue, state.runtime), state)

  @impl true
  def terminate(reason, state), do: AgentServer.terminate(reason, state.runtime)

  defp wrap_runtime_reply({:noreply, runtime}, state, false),
    do: {:noreply, %{state | runtime: runtime}}

  defp wrap_runtime_reply(result, state, false), do: wrap_runtime_reply(result, state)

  defp wrap_runtime_reply({:reply, reply, runtime}, state) do
    next = %{state | runtime: runtime}

    if Aikido.Ownership.parent(state.runtime) != Aikido.Ownership.parent(runtime) ||
         (runtime.sync.mode == :explicit && durable_changed?(state.runtime, runtime)),
       do: {:reply, reply, next, sync: true},
       else: {:reply, reply, next}
  end

  defp wrap_runtime_reply({:noreply, runtime}, state) do
    next = %{state | runtime: runtime}

    if Aikido.Ownership.parent(state.runtime) != Aikido.Ownership.parent(runtime) ||
         (runtime.sync.mode == :explicit && durable_changed?(state.runtime, runtime)),
       do: {:noreply, next, sync: true},
       else: {:noreply, next}
  end

  defp wrap_runtime_reply({:stop, reason, runtime}, state),
    do: {:stop, stop_reason(reason, runtime), %{state | runtime: runtime}}

  defp wrap_runtime_reply({:stop, reason, reply, runtime}, state),
    do: {:stop, stop_reason(reason, runtime), reply, %{state | runtime: runtime}}

  # Runtime observations, subscriber bookkeeping and debug reads do not change
  # the saved projection. Explicit mode requests sync only for persistent changes.
  defp durable_changed?(previous, next) do
    previous.agent != next.agent
  end

  defp stop_reason(:normal, runtime), do: stop_disposition(runtime)
  defp stop_reason(:shutdown, runtime), do: {:shutdown, stop_disposition(runtime)}
  defp stop_reason({:shutdown, _}, runtime), do: {:shutdown, stop_disposition(runtime)}
  defp stop_reason(reason, _runtime), do: {:error, reason}

  defp stop_disposition(runtime) do
    if Aikido.Durable.keep_snapshot?(runtime.agent_module), do: :permanent, else: :delete
  end

  defp encode(data), do: Aikido.Durable.Snapshot.dump(data)

  defp parent_binding(nil), do: nil
  defp parent_binding(parent), do: Map.take(parent, [:id, :partition, :tag, :meta])

  # Process references from an earlier incarnation never establish ownership.
  # Resolve the saved logical parent against the current runtime first.
  defp restore_parent(options) do
    case options[:parent] do
      %{id: id} = parent ->
        pool = options[:durable_server] || Aikido.durable_supervisor_name(options[:aikido])

        case lookup_saved_process(pool, id, parent[:partition]) do
          nil ->
            Keyword.delete(options, :parent)

          pid ->
            parent = parent |> Map.put(:pid, pid) |> restore_team_reference(pool)
            Keyword.put(options, :parent, parent)
        end

      _ ->
        options
    end
  end

  defp restore_team_reference(parent, pool) do
    meta = Map.get(parent, :meta, %{})

    if meta[:team_id] do
      pid = lookup_saved_process(pool, meta.team_id, parent[:partition])
      Map.put(parent, :meta, Map.put(meta, :team_pid, pid))
    else
      Map.put(parent, :meta, meta)
    end
  end

  defp lookup_saved_process(pool, id, partition) do
    case Aikido.Durable.lookup(pool, id, partition: partition) do
      {:ok, pid} -> pid
      :error -> nil
    end
  end

  defp serialize_agent(agent, agent_module) do
    if function_exported?(agent_module, :checkpoint, 2) do
      case agent_module.checkpoint(agent, %{}) do
        {:ok, checkpoint} when is_map(checkpoint) ->
          {:checkpoint, checkpoint}

        other ->
          raise ArgumentError,
                "Invalid checkpoint from #{inspect(agent_module)}: #{inspect(other)}"
      end
    else
      {:agent, agent}
    end
  end

  defp restore_agent({:checkpoint, checkpoint}, agent_module) do
    case agent_module.restore(checkpoint, %{}) do
      {:ok, %Aikido.Agent{} = agent} ->
        Aikido.Durable.Codec.transform_agent(agent, agent_module, :reinstate)

      other ->
        raise ArgumentError,
              "Invalid restoration from #{inspect(agent_module)}: #{inspect(other)}"
    end
  end

  defp restore_agent({:agent, agent}, agent_module),
    do: Aikido.Durable.Codec.transform_agent(agent, agent_module, :reinstate)

  defp restore_mounted_slices(agent, resource) do
    state =
      Enum.reduce(Aikido.Agent.Info.slice_instances(resource), agent.state, fn instance, state ->
        if Map.has_key?(state, instance.path),
          do: state,
          else: Map.put(state, instance.path, Ash.create!(instance.module, instance.config))
      end)

    %{agent | state: state}
  end

  # Read legacy manifests at the persistence boundary. New snapshots retain
  # definitions only inside the slice; the removed runtime fields stay removed.
  defp restore_cron_mount(agent, resource, legacy_specs) do
    mount =
      Enum.find(Aikido.Agent.Info.slice_instances(resource), &(&1.module == Aikido.Cron.Slice))

    cron = Map.get(agent.state, mount.path) || Ash.create!(Aikido.Cron.Slice, %{})

    cron =
      if map_size(legacy_specs) == 0,
        do: cron,
        else: Ash.update!(cron, %{specs: Map.merge(cron.specs, legacy_specs)})

    %{agent | state: Map.put(agent.state, mount.path, cron)}
  end

  defp enqueue_team_reconciliation(runtime) do
    resource = runtime.agent_module

    if Aikido.Agent.Info.team_config(resource) do
      send(self(), {:signal, Aikido.Signal.new!("aikido.ash.team.reconcile", %{})})
    end
  end
end
