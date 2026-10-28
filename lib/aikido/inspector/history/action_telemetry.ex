defmodule Aikido.Inspector.History.ActionTelemetry do
  @moduledoc """
  Correlates native Ash action timings with the signal executing in this process.

  Telemetry handlers execute synchronously in the emitting process. A bounded
  process-local observation records metadata only, never arguments or results.
  It is replaced on the next signal and disappears when the agent exits.

  Ash's action stop event runs in an `after` block, including on failures. Its
  duration means the action span ended, not that the action succeeded. Signal
  errors remain available separately in the inspector. Generic actions returning
  `Aikido.Types.ActionResult` contribute reducer observations. Other native spans
  retain stack markers so nested projection work preserves reducer timings.
  """
  use GenServer
  @key __MODULE__
  @limit 100

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    :ets.new(@key, [:named_table, :set, :protected, read_concurrency: true])

    events =
      for phase <- [:start, :stop, :exception],
          do: [:aikido, :agent_server, :signal, phase]

    :ok = :telemetry.attach_many(@key, Enum.uniq(events), &__MODULE__.handle_event/4, nil)
    {:ok, MapSet.new()}
  end

  @impl true
  def terminate(_, namespaces) do
    :telemetry.detach(@key)
    Enum.each(namespaces, &:telemetry.detach({@key, &1}))
    :ets.delete(@key)
  end

  @impl true
  def handle_call({:register, domain}, _, namespaces) do
    namespace = Ash.Domain.Info.short_name(domain)

    unless MapSet.member?(namespaces, namespace) do
      events =
        for phase <- [:start, :stop],
            do: [:ash, namespace, :action, phase]

      :ok = :telemetry.attach_many({@key, namespace}, events, &__MODULE__.handle_event/4, nil)
    end

    :ets.insert(@key, {domain})
    {:reply, :ok, MapSet.put(namespaces, namespace)}
  end

  defp register_domain(domain) do
    unless :ets.member(@key, domain), do: GenServer.call(__MODULE__, {:register, domain})
  end

  @doc "Read this signal's native action observations inside its subscription selector."
  def actions(signal_id) do
    case Process.get(@key) do
      %{signal_id: ^signal_id, entries: entries, count: count} ->
        %{entries: Enum.reverse(entries), count: count}

      _ ->
        %{entries: [], count: 0}
    end
  end

  @doc false
  def handle_event([:aikido, :agent_server, :signal, :start], _, metadata, _) do
    register_domain(Ash.EmbeddableType.ShadowDomain)
    register_domain(Ash.Resource.Info.domain(metadata.agent_module) || Aikido.RuntimeDomain)

    Process.put(@key, %{
      signal_id: metadata.signal_id,
      resource: metadata.agent_module,
      active?: true,
      entries: [],
      stack: [],
      count: 0
    })
  end

  def handle_event([:aikido, :agent_server, :signal, _], _, _, _) do
    if observation = Process.get(@key),
      do: Process.put(@key, %{observation | active?: false})
  end

  def handle_event([:ash, _, :action, phase], measurements, metadata, _) do
    case Process.get(@key) do
      %{active?: true} = observation ->
        observe_action(observation, phase, measurements, metadata)

      _ ->
        :ok
    end
  end

  defp observe_action(observation, :start, _, metadata) do
    case Ash.Resource.Info.action(metadata.resource, metadata.action) do
      %{type: :action, returns: Aikido.Types.ActionResult} = action ->
        observe_reducer(observation, metadata, action)

      _ ->
        Process.put(@key, %{observation | stack: [:ignored | observation.stack]})
    end
  end

  defp observe_action(%{stack: [:ignored | rest]} = observation, :stop, _, _),
    do: Process.put(@key, %{observation | stack: rest})

  defp observe_action(%{stack: [index | rest]} = observation, :stop, measurements, _) do
    duration = System.convert_time_unit(measurements.duration, :native, :microsecond) / 1000

    entries =
      Enum.map(observation.entries, fn entry ->
        if entry.index == index, do: %{entry | duration_ms: duration}, else: entry
      end)

    Process.put(@key, %{observation | entries: entries, stack: rest})
  end

  defp observe_action(_, _, _, _), do: :ok

  defp observe_reducer(observation, metadata, action) do
    index = observation.count + 1

    entry = %{
      index: index,
      resource: inspect(metadata.resource),
      action: to_string(metadata.action),
      implementation: inspect(elem(action.run, 0)),
      mount_paths:
        observation.resource
        |> Aikido.Agent.Info.slice_paths_for_action()
        |> Map.get({metadata.resource, metadata.action}, [
          Spark.Dsl.Extension.get_opt(observation.resource, [:agent], :path)
        ])
        |> Enum.map(&to_string/1),
      duration_ms: nil
    }

    entries = if index <= @limit, do: [entry | observation.entries], else: observation.entries

    Process.put(@key, %{
      observation
      | count: index,
        entries: entries,
        stack: [index | observation.stack]
    })
  end
end
