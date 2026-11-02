Code.require_file("support/quicksort_lifecycle_probe.exs", __DIR__)

defmodule AgentExamples.Quicksort.Bench.Repeated do
  @moduledoc false
  @profile [
    {EKV.Store, :truncate_oplog_batch, 3},
    {EKV.Store, :purge_orphan_keyrefs, 1},
    {EKV.Store, :purge_orphan_paxos, 1},
    {EKV.Store, :clear_paxos_accepted, 2},
    {EKV.Sqlite3, :paxos_prepare, 4},
    {EKV.Sqlite3, :paxos_accept, 5},
    {EKV.Sqlite3, :paxos_promote, 8}
  ]

  def run(argv) do
    {options, _, []} =
      OptionParser.parse(argv,
        strict: [
          runs: :integer,
          size: :integer,
          output: :string,
          profile: :boolean,
          truncate_wal: :boolean
        ]
      )

    File.mkdir_p!(System.fetch_env!("AIKIDO_DURABLE_DIR"))
    runs = options[:runs] || 10
    size = options[:size] || 100_000
    true = runs > 0 && size in 1..100_000
    ensure_disk_capacity!(size)
    guard = start_disk_guard()
    output = Path.expand(options[:output] || "_build/quicksort-repeated.jsonl")
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, "")
    owner = "quicksort-benchmark:" <> Ash.UUIDv7.generate()
    {:ok, _} = AgentExamples.Playground.start(owner, "quicksort", %{})
    append(output, %{phase: :baseline, resources: resources()})

    if options[:profile], do: :erlang.trace(:all, true, [:call])

    try do
      for iteration <- 1..runs do
        :rand.seed(:exsss, {42 + iteration, 43, 44})
        if options[:profile], do: reset_profile()
        ensure_disk_capacity!(size)
        report = run_once(owner, iteration, size, output)

        report =
          if options[:truncate_wal],
            do: Map.put(report, :wal_maintenance, truncate_quiescent_wal()),
            else: report

        report =
          if options[:profile], do: Map.put(report, :native_profile, profile()), else: report

        append(output, report)
      end
    catch
      kind, reason ->
        append(output, %{
          phase: :failed,
          kind: kind,
          error: Exception.format(kind, reason, __STACKTRACE__),
          native_profile: if(options[:profile], do: profile()),
          resources: resources()
        })

        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      if options[:profile] do
        :erlang.trace(:all, false, [:call])
        for mfa <- @profile, do: :erlang.trace_pattern(mfa, false, [:call_time])
      end

      send(guard, :stop)
      cleanup = stop_benchmark_run(owner)
      append(output, %{phase: :final, cleanup: inspect(cleanup), resources: resources()})
    end
  end

  defp stop_benchmark_run(owner) do
    AgentExamples.Playground.stop(owner, "quicksort")
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp run_once(owner, iteration, size, output) do
    root = AgentExamples.Playground.get(owner, "quicksort").record
    topic = AgentExamples.Quicksort.RunHistory.topic(Ash.UUIDv7.generate())
    AgentExamples.Quicksort.RunHistory.open(topic)
    {:ok, probe} = AgentExamples.Quicksort.Bench.LifecycleProbe.start(root, size, topic)
    numbers = Enum.shuffle(Enum.to_list(1..size))
    IO.puts("Run #{iteration}: sorting #{size} agents with recursive inspection")

    try do
      {sort_us, {:ok, :verified}} =
        :timer.tc(fn ->
          Aikido.AgentServer.call_until(
            root.pid,
            fn ->
              AgentExamples.Playground.command(owner, "quicksort", :sort, %{
                numbers: numbers,
                topic: topic
              })
            end,
            "**",
            fn runtime ->
              state = runtime.agent.state.state

              case state.status do
                :completed ->
                  if state.result == Enum.to_list(1..size),
                    do: {:ok, :verified},
                    else: {:error, :invalid_result}

                :failed ->
                  {:error, state.error}

                _ ->
                  :skip
              end
            end,
            timeout: 600_000
          )
        end)

      IO.puts(
        "Run #{iteration}: sorted result verified in #{Float.round(sort_us / 1_000_000, 3)}s"
      )

      {retirement_us, lifecycle} =
        :timer.tc(fn -> AgentExamples.Quicksort.Bench.LifecycleProbe.await(probe) end)

      IO.puts("Run #{iteration}: all child processes retired; restarting the root")

      if lifecycle.failures != [],
        do: raise("Unexpected worker exits: #{inspect(lifecycle, limit: 15)}")

      {restart_us, {:ok, fresh}} =
        :timer.tc(fn -> AgentExamples.Quicksort.Restart.restart(owner) end)

      true = fresh.record.id != root.id
      true = fresh.record.pid != root.pid
      :error = AgentExamples.Quicksort.RunHistory.fetch(topic)
      GenServer.stop(probe)

      %{
        phase: :run,
        iteration: iteration,
        size: size,
        root_id: root.id,
        sort_us: sort_us,
        retirement_us: retirement_us,
        restart_us: restart_us,
        lifecycle: lifecycle,
        resources: resources()
      }
    catch
      kind, reason ->
        append(output, %{
          phase: :attempt_failed,
          iteration: iteration,
          root_id: root.id,
          lifecycle: AgentExamples.Quicksort.Bench.LifecycleProbe.snapshot(probe)
        })

        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      if Process.alive?(probe), do: GenServer.stop(probe)
    end
  end

  # This diagnostic is opt-in: it must never be confused with the normal restart path.
  defp truncate_quiescent_wal do
    pool = Aikido.durable_supervisor_name(Aikido.Default)
    true = length(Aikido.Durable.members(pool)) == 1
    directory = System.fetch_env!("AIKIDO_DURABLE_DIR") |> Path.expand()

    for path <- Path.wildcard(Path.join(directory, "shard_*.db")) do
      {:ok, db} = EKV.Store.open_checkpointer(path, 64 * 1024 * 1024)

      try do
        {elapsed, result} =
          :timer.tc(fn -> EKV.Sqlite3.fetch_all(db, "PRAGMA wal_checkpoint(TRUNCATE)", []) end)

        %{shard: Path.basename(path), duration_us: elapsed, result: inspect(result)}
      after
        EKV.Sqlite3.close(db)
      end
    end
  end

  defp ensure_disk_capacity!(size) do
    required = max(4_000_000_000, size * 120_000)

    if available_disk_bytes() < required,
      do: raise("Benchmark requires at least #{required} bytes of free workspace disk space")
  end

  defp available_disk_bytes do
    {text, 0} = System.cmd("df", ["-Pk", System.fetch_env!("AIKIDO_DURABLE_DIR")])

    [_filesystem, _size, _used, available | _] =
      text |> String.split("\n", trim: true) |> List.last() |> String.split()

    String.to_integer(available) * 1024
  end

  defp start_disk_guard do
    owner = self()

    spawn(fn ->
      ref = Process.monitor(owner)
      watch_disk(ref)
    end)
  end

  defp watch_disk(ref) do
    receive do
      :stop -> :ok
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      1_000 ->
        if available_disk_bytes() < 2_000_000_000 do
          IO.puts(:stderr, "Stopping this benchmark VM: less than 2 GB of disk space remains")
          System.stop(75)
        else
          watch_disk(ref)
        end
    end
  end

  defp resources do
    pool = Aikido.durable_supervisor_name(Aikido.Default)
    config = DurableServer.Supervisor.__get_config__(pool)
    store = config.storage_backend.state.name
    directory = System.fetch_env!("AIKIDO_DURABLE_DIR") |> Path.expand()
    files = Path.wildcard(Path.join(directory, "shard_*.db"))
    shards = Enum.map(files, &shard_metrics/1)

    saved =
      DurableServer.StorageBackend.list_all_objects_stream(config.storage_backend, config.prefix,
        include_objects: true
      )
      |> Enum.count(&match?(%{body: %DurableServer.StoredState{}}, &1))

    %{
      vm_pid: System.pid(),
      directory: directory,
      backend_timeout_ms: config.storage_backend.state.timeout,
      beam_memory: Map.new(:erlang.memory()),
      top_processes: process_sizes(),
      top_ets: ets_sizes(),
      histories: Agent.get(AgentExamples.Quicksort.RunHistory, &map_size/1),
      processes: :erlang.system_info(:process_count),
      ports: :erlang.system_info(:port_count),
      atoms: :erlang.system_info(:atom_count),
      io_tasks: length(Task.Supervisor.children(Aikido.task_supervisor_name(Aikido.Default))),
      agents: length(Aikido.Durable.members(pool)),
      local_agents: DurableServer.Supervisor.count_children(pool).active,
      saved_agents: saved,
      shards: shards,
      wal:
        for(
          index <- 0..(length(files) - 1),
          do: Map.put(EKV.WALCheckpointer.stats(store, index), :shard, index)
        ),
      os: os_memory()
    }
  end

  defp shard_metrics(path) do
    {:ok, db} = EKV.Sqlite3.open(path)

    try do
      totals =
        for table <- ["kv", "kv_paxos", "kv_keyrefs", "kv_oplog"], into: %{} do
          {:ok, [[count]]} = EKV.Sqlite3.fetch_all(db, "SELECT count(*) FROM " <> table, [])
          {table, count}
        end

      {:ok, [[live, deleted]]} =
        EKV.Sqlite3.fetch_all(
          db,
          "SELECT count(*) FILTER (WHERE deleted_at IS NULL), count(*) FILTER (WHERE deleted_at IS NOT NULL) FROM kv",
          []
        )

      {:ok, [[pages]]} = EKV.Sqlite3.fetch_all(db, "PRAGMA page_count", [])
      {:ok, [[free]]} = EKV.Sqlite3.fetch_all(db, "PRAGMA freelist_count", [])

      Map.merge(totals, %{
        name: Path.basename(path),
        live: live,
        deleted: deleted,
        pages: pages,
        free_pages: free,
        bytes: File.stat!(path).size,
        wal_bytes:
          case File.stat(path <> "-wal") do
            {:ok, stat} -> stat.size
            _ -> 0
          end
      })
    after
      EKV.Sqlite3.close(db)
    end
  end

  defp process_sizes do
    Process.list()
    |> Enum.flat_map(fn pid ->
      case Process.info(pid, [:memory, :registered_name, :current_function]) do
        nil ->
          []

        values ->
          [
            %{
              pid: inspect(pid),
              bytes: values[:memory],
              name: inspect(values[:registered_name]),
              function: inspect(values[:current_function])
            }
          ]
      end
    end)
    |> Enum.sort_by(& &1.bytes, :desc)
    |> Enum.take(12)
  end

  defp ets_sizes do
    :ets.all()
    |> Enum.flat_map(fn table ->
      case :ets.info(table) do
        :undefined ->
          []

        values ->
          [
            %{
              name: inspect(values[:name]),
              size: values[:size],
              bytes: values[:memory] * :erlang.system_info(:wordsize)
            }
          ]
      end
    end)
    |> Enum.sort_by(& &1.bytes, :desc)
    |> Enum.take(12)
  end

  defp reset_profile do
    for {module, _, _} = mfa <- @profile do
      Code.ensure_loaded!(module)
      :erlang.trace_pattern(mfa, false, [:call_time])
      :erlang.trace_pattern(mfa, true, [:call_time])
    end
  end

  defp profile do
    Map.new(@profile, fn mfa ->
      {:call_time, entries} = :erlang.trace_info(mfa, :call_time)

      totals =
        Enum.reduce(entries, %{calls: 0, microseconds: 0}, fn {_, calls, seconds, micros}, sum ->
          %{
            calls: sum.calls + calls,
            microseconds: sum.microseconds + seconds * 1_000_000 + micros
          }
        end)

      {inspect(mfa), totals}
    end)
  end

  defp os_memory do
    case File.read("/proc/self/smaps_rollup") do
      {:ok, text} ->
        Regex.scan(~r/^(Rss|Pss|Anonymous|Swap):\s+(\d+) kB/m, text)
        |> Map.new(fn [_, key, value] -> {key, String.to_integer(value) * 1024} end)

      _ ->
        %{}
    end
  end

  defp append(output, report) do
    File.write!(output, Jason.encode!(Map.put(report, :at, DateTime.utc_now())) <> "\n", [:append])

    IO.puts("Recorded #{report.phase} #{Map.get(report, :iteration, "")} to #{output}")
  end
end

AgentExamples.Quicksort.Bench.Repeated.run(System.argv())
