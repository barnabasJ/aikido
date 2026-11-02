# Run with mix run --no-start bench/quicksort_scale.exs.
# Uses a separate native EKV store; never opens the playground's store or credentials.
Code.require_file("support/quicksort_runtime_profile.exs", __DIR__)
Code.require_file("support/quicksort_storage_trace.exs", __DIR__)

Application.put_env(:ash, :default_string_length_count, :codepoints)
Application.put_env(:agent_examples, :ash_domains, [AgentExamples.Agents])
Logger.configure(level: :warning)

for app <- [:aikido, :phoenix_pubsub] do
  {:ok, _} = Application.ensure_all_started(app)
end

defmodule AgentExamples.Quicksort.Bench.Scale.Sample do
  use GenServer
  def start_link(config), do: GenServer.start_link(__MODULE__, config)
  def finish(pid), do: GenServer.call(pid, :finish, 30_000)

  def init(config) do
    send(self(), :sample)

    {:ok,
     Map.merge(config, %{
       samples: [],
       latencies: [],
       wall: AgentExamples.Quicksort.Bench.RuntimeProfile.wall_time(),
       started: System.monotonic_time(:millisecond)
     })}
  end

  def handle_info({:storage_probe, shard, latency, outcome}, state) do
    sample = %{shard: shard, latency_ms: latency, outcome: inspect(outcome)}
    File.write!(state.output <> ".storage.jsonl", Jason.encode!(sample) <> "\n", [:append])
    {:noreply, %{state | latencies: [sample | state.latencies]}}
  end

  def handle_info(:sample, state) do
    writers =
      for index <- 0..(state.shards - 1) do
        pid =
          Process.whereis(
            EKV.Replica.shard_name(AgentExamples.Quicksort.Bench.Scale.Store, index)
          )

        info =
          if pid,
            do:
              Process.info(pid, [
                :message_queue_len,
                :memory,
                :current_function,
                :current_stacktrace
              ]),
            else: []

        %{
          shard: index,
          queue: info[:message_queue_len],
          memory: info[:memory],
          current_function: inspect(info[:current_function]),
          current_stacktrace: inspect(info[:current_stacktrace], limit: 12)
        }
      end

    files = Path.wildcard(Path.join(state.directory, "**/*"))

    sizes =
      for path <- files, String.ends_with?(path, [".db", "-wal"]) do
        case File.stat(path) do
          {:ok, stat} -> {Path.relative_to(path, state.directory), stat.size}
          _ -> {Path.relative_to(path, state.directory), 0}
        end
      end

    wall = AgentExamples.Quicksort.Bench.RuntimeProfile.wall_time()

    sample = %{
      scheduler_utilization:
        AgentExamples.Quicksort.Bench.RuntimeProfile.utilization(state.wall, wall),
      signals_processed:
        case :ets.lookup(AgentExamples.Telemetry.Observations, :signals_processed) do
          [{_, count}] -> count
          _ -> 0
        end,
      elapsed_ms: System.monotonic_time(:millisecond) - state.started,
      monotonic_ms: System.monotonic_time(:millisecond),
      memory_bytes: :erlang.memory(:total),
      processes: :erlang.system_info(:process_count),
      run_queue: :erlang.statistics(:run_queue),
      writers: writers,
      files: Map.new(sizes),
      heartbeat: heartbeat(),
      ready: :ets.info(state.ids, :size),
      errors: :ets.info(state.errors, :size)
    }

    File.write!(state.output <> ".samples.jsonl", Jason.encode!(sample) <> "\n", [:append])
    Process.send_after(self(), :sample, 1000)
    {:noreply, %{state | samples: [sample | state.samples], wall: wall}}
  end

  defp heartbeat do
    pool = Aikido.durable_supervisor_name(Aikido.Default)
    metrics = DurableServer.LifecycleManager.get_heartbeat_metrics(pool)

    %{
      age_ms: max(System.system_time(:millisecond) - metrics.last_successful_heartbeat_at, 0),
      put_ms: metrics.last_heartbeat_timing.put_ms,
      total_ms: metrics.last_heartbeat_timing.total_ms,
      deadline_ms: metrics.deadline_ms
    }
  catch
    :exit, _ -> %{unavailable: true}
  end

  def handle_call(:finish, _, state),
    do:
      {:stop, :normal,
       %{samples: Enum.reverse(state.samples), latencies: Enum.reverse(state.latencies)}, state}
end

defmodule AgentExamples.Quicksort.Bench.Scale do
  def telemetry(event, _measurements, metadata, {ids, errors}) do
    if event == [:aikido, :agent_server, :ready] do
      :ets.insert(ids, {metadata.agent_id})
    else
      if metadata[:error] || List.last(event) == :exception ||
           metadata[:signal_type] == "aikido.agent.child.start_failed" do
        :ets.insert(
          errors,
          {System.unique_integer([:positive]), inspect({event, metadata}, limit: 30)}
        )
      end
    end
  end

  def run do
    bootstrap_started = System.monotonic_time(:millisecond)

    directory =
      Path.expand(System.get_env("SCALE_STORE", "tmp/quicksort-scale/store-#{System.pid()}"))

    File.mkdir_p!(System.get_env("SCALE_OUTPUT", "tmp/quicksort-scale"))
    IO.puts("SCALE STORE #{directory} bootstrap_at=#{DateTime.utc_now()}")

    shards = String.to_integer(System.get_env("SCALE_SHARDS", "8"))
    existing = Path.wildcard(Path.join(directory, "shard_*.db")) |> length()

    if existing > 0 and existing != shards,
      do: raise("Refusing to change shard placement of an existing benchmark store")

    heartbeat_mode = System.get_env("SCALE_HEARTBEAT", "isolated")

    heartbeat_options =
      case heartbeat_mode do
        "shared" ->
          []

        "isolated" ->
          [
            heartbeat_backend:
              {DurableServer.Backends.EKVStore,
               name: AgentExamples.Quicksort.Bench.Scale.HeartbeatStore,
               data_dir: Path.join(directory, "heartbeats"),
               cluster_size: 1,
               node_id: "scale",
               shards: 1}
          ]
      end

    {:ok, sup} =
      Supervisor.start_link(
        [
          {EKV,
           name: AgentExamples.Quicksort.Bench.Scale.Store,
           data_dir: directory,
           cluster_size: 1,
           node_id: "scale",
           shards: shards,
           gc_interval: 30_000},
          {Aikido,
           max_tasks: 20_000,
           durable: [
             prefix: System.get_env("SCALE_PREFIX", "scale/#{System.pid()}/"),
             durable_options: heartbeat_options,
             backend:
               {DurableServer.Backends.EKVStore, name: AgentExamples.Quicksort.Bench.Scale.Store}
           ]},
          {Phoenix.PubSub, name: AgentExamples.PubSub},
          AgentExamples.Telemetry.Observations,
          AgentExamples.Quicksort.RunHistory
        ],
        strategy: :one_for_one
      )

    store_config = EKV.Supervisor.get_config(AgentExamples.Quicksort.Bench.Scale.Store)

    bootstrap = %{
      elapsed_ms: System.monotonic_time(:millisecond) - bootstrap_started,
      data_shards: store_config.num_shards,
      gc_interval_ms: store_config.gc_interval,
      directory: directory
    }

    File.write!(
      Path.join(
        System.get_env("SCALE_OUTPUT", "tmp/quicksort-scale"),
        "bootstrap-#{System.pid()}.json"
      ),
      Jason.encode!(bootstrap)
    )

    sizes =
      System.get_env("SCALE_SIZES", "1024,10000,50000")
      |> String.split(",")
      |> Enum.map(&String.to_integer/1)

    modes =
      case System.get_env("SCALE_CAPTURE", "both") do
        "off" -> [false]
        "on" -> [true]
        "both" -> [false, true]
      end

    schedulers =
      System.get_env(
        "SCALE_SCHEDULERS",
        Integer.to_string(:erlang.system_info(:schedulers_online))
      )
      |> String.split(",")
      |> Enum.map(&String.to_integer/1)

    :erlang.system_flag(:scheduler_wall_time, true)

    for count <- schedulers do
      :erlang.system_flag(:schedulers_online, count)
      for size <- sizes, capture <- modes, do: measure(directory, size, capture)
    end

    Supervisor.stop(sup, :normal, 120_000)
    IO.puts("SCALE VERIFICATION COMPLETE")
  end

  defp measure(directory, size, capture) do
    shards = EKV.Supervisor.get_config(AgentExamples.Quicksort.Bench.Scale.Store).num_shards
    ids = :ets.new(:scale_ids, [:public, :set])
    errors = :ets.new(:scale_errors, [:public, :set])
    handler = {__MODULE__, make_ref()}

    events = [
      [:aikido, :agent_server, :ready],
      [:aikido, :agent_server, :signal, :stop],
      [:aikido, :agent_server, :signal, :exception],
      [:aikido, :agent_server, :directive, :exception]
    ]

    :ok = :telemetry.attach_many(handler, events, &__MODULE__.telemetry/4, {ids, errors})

    output =
      Path.join(
        System.get_env("SCALE_OUTPUT", "tmp/quicksort-scale"),
        "scale-#{System.pid()}-w#{shards}-s#{:erlang.system_info(:schedulers_online)}-#{size}-#{capture}"
      )

    {:ok, sampler} =
      AgentExamples.Quicksort.Bench.Scale.Sample.start_link(%{
        directory: directory,
        output: output,
        ids: ids,
        errors: errors,
        shards: shards
      })

    probes =
      for shard <- 0..(shards - 1) do
        key =
          Stream.iterate(0, &(&1 + 1))
          |> Enum.find_value(fn n ->
            key = "scale-canary/#{shard}/#{n}"
            if EKV.Replica.shard_index_for(key, shards) == shard, do: key
          end)

        spawn_link(fn -> probe(sampler, shard, key) end)
      end

    :rand.seed(:exsss, {42, 43, 44})
    expected = Enum.to_list(1..size)
    numbers = Enum.shuffle(expected)
    root = AgentExamples.Agents.quicksort_start!(%{sync: %{mode: :periodic, interval_ms: 30_000}})
    sink = spawn_link(fn -> drain() end)

    inspector =
      if capture do
        {:ok, ref} =
          Aikido.Inspector.attach(root, &AgentExamples.Playground.snapshot/2,
            target: sink,
            include_children?: true
          )

        ref
      end

    topic = AgentExamples.Quicksort.RunHistory.topic(root.id)
    :ok = AgentExamples.Quicksort.RunHistory.open(topic)
    before_io = io()
    IO.puts("START #{size} agents capture=#{capture} root=#{root.id} at=#{DateTime.utc_now()}")
    signal = AgentExamples.Quicksort.Signals.Sort.new!(%{numbers: numbers, topic: topic})

    storage_tracer = AgentExamples.Quicksort.Bench.StorageTrace.start(output)
    AgentExamples.Quicksort.Bench.RuntimeProfile.start()

    {sort_us, result} =
      :timer.tc(fn ->
        Aikido.AgentServer.call_until(
          root.pid,
          signal,
          "quicksort.**",
          fn runtime ->
            case runtime.agent.state.state do
              %{status: :completed, result: values} -> {:ok, values}
              %{status: :failed, error: error} -> {:error, error}
              _ -> :skip
            end
          end,
          timeout: 600_000
        )
      end)

    AgentExamples.Quicksort.Bench.RuntimeProfile.finish(output)
    AgentExamples.Quicksort.Bench.StorageTrace.finish(storage_tracer, output)
    pool = Aikido.durable_supervisor_name(Aikido.Default)

    children =
      for {_, pid} <- Aikido.Durable.members(pool), pid != root.pid, do: Process.monitor(pid)

    {retire_us, :ok} = :timer.tc(fn -> await_down(MapSet.new(children)) end)
    {:ok, tree} = AgentExamples.Quicksort.RunHistory.fetch(topic)
    if inspector, do: Aikido.Inspector.detach(inspector)
    monitor = Process.monitor(root.pid)

    {stop_us, :ok} =
      :timer.tc(fn ->
        AgentExamples.Agents.quicksort_stop!(root)
        await_down(MapSet.new([monitor]))
      end)

    refs =
      for pid <- probes do
        ref = Process.monitor(pid)
        send(pid, :stop)
        ref
      end

    await_down(MapSet.new(refs))

    %{samples: samples, latencies: latencies} =
      AgentExamples.Quicksort.Bench.Scale.Sample.finish(sampler)

    after_io = io()
    config = DurableServer.Supervisor.__get_config__(pool)

    snapshots =
      DurableServer.StorageBackend.list_all_objects_stream(config.storage_backend, config.prefix,
        include_objects: true
      )
      |> Enum.count(fn object ->
        match?(%{body: %DurableServer.StoredState{}}, object)
      end)

    report = %{
      seed: [42, 43, 44],
      ekv_shards: shards,
      ekv_gc_interval_ms:
        EKV.Supervisor.get_config(AgentExamples.Quicksort.Bench.Scale.Store).gc_interval,
      sync: %{mode: :periodic, interval_ms: 30_000},
      schedulers: :erlang.system_info(:schedulers_online),
      size: size,
      inspector: capture,
      root_id: root.id,
      sorted_correctly: result == {:ok, expected},
      result_summary:
        case result do
          {:ok, values} ->
            %{status: :ok, values: length(values)}

          {:error, reason} ->
            %{status: :error, reason: inspect(reason, limit: 20, printable_limit: 500)}
        end,
      ekv_candidate: not is_nil(System.get_env("EKV_CANDIDATE_SOURCE")),
      sort_ms: sort_us / 1000,
      child_retirement_ms: retire_us / 1000,
      root_stop_ms: stop_us / 1000,
      children_at_result: length(children),
      agents_started: :ets.info(ids, :size),
      display_nodes: map_size(tree.nodes),
      display_completed: tree.completed,
      display_failed: tree.failed,
      remaining_agents: length(Aikido.Durable.members(pool)),
      saved_agent_snapshots: snapshots,
      local_agents: DurableServer.Supervisor.count_children(pool).active,
      errors: Enum.map(:ets.tab2list(errors), fn {_, error} -> error end),
      peak_memory_bytes: samples |> Enum.map(& &1.memory_bytes) |> Enum.max(fn -> 0 end),
      peak_writer_queue:
        samples
        |> Enum.flat_map(& &1.writers)
        |> Enum.map(&(&1.queue || 0))
        |> Enum.max(fn -> 0 end),
      heartbeat_isolated:
        config.heartbeat_backend.state.name != config.storage_backend.state.name,
      heartbeat_store: inspect(config.heartbeat_backend.state.name),
      heartbeat_max_age_ms:
        samples |> Enum.map(&Map.get(&1.heartbeat, :age_ms, 0)) |> Enum.max(fn -> 0 end),
      heartbeat_max_put_ms:
        samples |> Enum.map(&Map.get(&1.heartbeat, :put_ms, 0)) |> Enum.max(fn -> 0 end),
      heartbeat_unavailable_samples:
        Enum.count(samples, &Map.get(&1.heartbeat, :unavailable, false)),
      canary_writes: length(latencies),
      canary_max_ms: latencies |> Enum.map(& &1.latency_ms) |> Enum.max(fn -> 0 end),
      canary_errors: Enum.reject(latencies, &String.starts_with?(&1.outcome, "{:ok,")),
      io: Map.new(after_io, fn {key, value} -> {key, value - before_io[key]} end)
    }

    File.write!(output <> ".json", Jason.encode!(report))
    IO.inspect(report, label: "SCALE RESULT", limit: :infinity)
    :telemetry.detach(handler)
    send(sink, :stop)
    AgentExamples.Quicksort.RunHistory.close(topic)
    :ets.delete(ids)
    :ets.delete(errors)

    unless report.sorted_correctly && report.agents_started == size &&
             report.display_completed == size &&
             report.display_failed == 0 && report.remaining_agents == 0 &&
             report.local_agents == 0 && snapshots == 0 && report.errors == [] &&
             report.canary_errors == [],
           do: raise("Scale verification failed; see #{output}.json")
  end

  defp probe(sampler, shard, key) do
    {us, outcome} =
      :timer.tc(fn ->
        try do
          EKV.put(AgentExamples.Quicksort.Bench.Scale.Store, key, "canary",
            consistent: true,
            timeout: 2000
          )
        catch
          kind, reason -> {:probe_failure, kind, reason}
        end
      end)

    send(sampler, {:storage_probe, shard, us / 1000, outcome})

    receive do
      :stop -> :ok
    after
      1000 -> probe(sampler, shard, key)
    end
  end

  defp drain do
    receive do
      :stop -> :ok
      _ -> drain()
    end
  end

  defp await_down(refs) do
    if MapSet.size(refs) == 0 do
      :ok
    else
      receive do
        {:DOWN, ref, :process, _, _} -> await_down(MapSet.delete(refs, ref))
      after
        120_000 -> raise "Child retirement timed out"
      end
    end
  end

  defp io do
    File.read!("/proc/#{System.pid()}/io")
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [key, value] = String.split(line, ":", parts: 2)
      {key, String.to_integer(String.trim(value))}
    end)
  end
end

AgentExamples.Quicksort.Bench.Scale.run()
