defmodule Aikido.Durable.AgentServer do
  @moduledoc false
  use DurableServer, vsn: 2
  alias Aikido.AgentServer

  @impl true
  def dump_state(%{require_existing?: true}) do
    raise Aikido.Durable.ScopeAdapter.Error, operation: :restore, reason: :saved_state_missing
  end

  def dump_state(%{runtime: runtime} = state) do
    credential =
      Aikido.Durable.ScopeAdapter.checkpoint(
        state[:scope_adapter],
        state[:credential],
        runtime.agent,
        Aikido.Durable.ScopeAdapter.identity(state.options)
      )

    agent =
      Aikido.Durable.Codec.transform_agent(runtime.agent, runtime.agent_module, :externalize)

    encode(%{
      options: Aikido.Durable.Snapshot.boot_options(state.options),
      parent: parent_binding(Aikido.Ownership.parent(runtime)) || state[:unresolved_parent],
      permanent: state.permanent,
      credential: credential,
      agent: serialize_agent(agent, runtime.agent_module)
    })
  end

  # DurableServer re-dumps a loaded envelope while claiming its initialization
  # lock, before initialization has reconstructed the runtime. Its codecs already ran.
  def dump_state(%{agent: _, options: _, permanent: _} = saved), do: encode(saved)

  def dump_state(%{options: _} = initial), do: dump_initial_state(initial, [])

  defp dump_initial_state(%{options: options} = initial, initialization_options) do
    module = Keyword.fetch!(options, :agent_module)
    Code.ensure_loaded!(module)

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
  def init(saved), do: init(saved, %{})

  @impl true
  def init(saved, info) do
    saved_parent = Map.get(saved, :parent, saved.options[:parent])
    saved_options = Aikido.Durable.Snapshot.boot_options(saved.options)

    adapter = get_in(info, [:aikido_config, :scope_adapter])
    identity = Aikido.Durable.ScopeAdapter.identity(saved_options)

    with :ok <- validate_claim(saved_options, info),
         {:ok, scope} <-
           Aikido.Durable.ScopeAdapter.restore(
             adapter,
             saved[:credential],
             saved.agent,
             identity
           ) do
      initialize_authenticated(saved, saved_options, saved_parent, adapter, scope)
    else
      {:error, reason} ->
        raise Aikido.Durable.ScopeAdapter.Error, operation: :restore, reason: reason
    end
  end

  defp validate_claim(options, %{key: claimed_key, supervisor: claimed_pool} = info) do
    configured_instance = get_in(info, [:aikido_config, :aikido])

    if options[:durable_server] == claimed_pool &&
         Aikido.Durable.storage_key(options[:durable_key], options[:partition]) == claimed_key &&
         Aikido.Durable.agent_id(options[:durable_key]) == options[:id] &&
         options[:aikido] == configured_instance do
      :ok
    else
      {:error, :durable_identity_mismatch}
    end
  end

  defp validate_claim(_options, _info), do: {:error, :missing_durable_claim}

  defp initialize_authenticated(saved, saved_options, saved_parent, adapter, scope) do
    options =
      saved_options
      |> Keyword.put(:parent, saved_parent)
      |> Keyword.put(:initialization_options, scope)
      |> restore_parent()

    unresolved_parent =
      if saved_parent && is_nil(options[:parent]) &&
           options[:on_parent_death] not in [:continue, :emit_orphan],
         do: saved_parent

    {options, restored?} = activation_state(saved, options)

    case AgentServer.init(options) do
      {:ok, runtime, {:continue, continue}} ->
        send(
          self(),
          {:aikido_durable_continue, continue, restored?}
        )

        if unresolved_parent, do: send(self(), :aikido_missing_parent)

        {:ok,
         %{
           runtime: runtime,
           options: saved_options,
           scope_adapter: adapter,
           credential: saved[:credential],
           permanent: saved.permanent,
           unresolved_parent: unresolved_parent
         },
         permanent: saved.permanent,
         auto_sync: runtime.sync.mode == :automatic,
         sync_every_ms: runtime.sync.interval_ms,
         meta: %{
           key: runtime.durable_key,
           partition: runtime.partition,
           restored?: restored?
         }}

      {:stop, reason} ->
        raise "Cannot initialize durable agent: #{inspect(reason)}"
    end
  end

  defp activation_state(%{agent: {:uninitialized, attributes}} = saved, options) do
    attributes =
      Aikido.Durable.Codec.reinstate_initial(
        attributes,
        options[:agent_module],
        Map.get(saved, :bootstrap_codecs, [])
      )

    {Keyword.put(options, :initial_state, attributes), false}
  end

  defp activation_state(saved, options) do
    agent =
      saved.agent
      |> restore_agent(options[:agent_module], options[:initialization_options])
      |> restore_mounted_slices(options[:agent_module], options[:initialization_options])
      |> restore_cron_mount(
        options[:agent_module],
        Map.get(saved, :cron_specs, %{}),
        options[:initialization_options]
      )

    {Keyword.put(options, :restored_agent, agent), !Map.get(saved, :initial?, false)}
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
  def handle_info({:aikido_durable_continue, {:post_init, scope} = continue, restored?}, state) do
    result = AgentServer.handle_continue(continue, state.runtime)
    if restored?, do: enqueue_team_reconciliation(state.runtime, scope)
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

  defp restore_agent({:checkpoint, checkpoint}, agent_module, scope) do
    case agent_module.restore(checkpoint, %{scope: Map.new(scope)}) do
      {:ok, %Aikido.Agent{} = agent} ->
        Aikido.Durable.Codec.transform_agent(agent, agent_module, :reinstate)

      other ->
        raise ArgumentError,
              "Invalid restoration from #{inspect(agent_module)}: #{inspect(other)}"
    end
  end

  defp restore_agent({:agent, agent}, agent_module, _scope),
    do: Aikido.Durable.Codec.transform_agent(agent, agent_module, :reinstate)

  defp restore_mounted_slices(agent, resource, scope) do
    state =
      Enum.reduce(Aikido.Agent.Info.slice_instances(resource), agent.state, fn instance, state ->
        if Map.has_key?(state, instance.path),
          do: state,
          else:
            Map.put(state, instance.path, Ash.create!(instance.module, instance.config, scope))
      end)

    %{agent | state: state}
  end

  # Read legacy manifests at the persistence boundary. New snapshots retain
  # definitions only inside the slice; the removed runtime fields stay removed.
  defp restore_cron_mount(agent, resource, legacy_specs, scope) do
    mount =
      Enum.find(Aikido.Agent.Info.slice_instances(resource), &(&1.module == Aikido.Cron.Slice))

    cron = Map.get(agent.state, mount.path) || Ash.create!(Aikido.Cron.Slice, %{}, scope)

    cron =
      if map_size(legacy_specs) == 0,
        do: cron,
        else: Ash.update!(cron, %{specs: Map.merge(cron.specs, legacy_specs)}, scope)

    %{agent | state: Map.put(agent.state, mount.path, cron)}
  end

  defp enqueue_team_reconciliation(runtime, scope) do
    resource = runtime.agent_module

    if Aikido.Agent.Info.team_config(resource) do
      signal =
        Aikido.Signal.new!("aikido.ash.team.reconcile", %{}, scope: scope)
        |> Aikido.Signal.capture_tracing()

      send(self(), {:signal, signal})
    end
  end
end
