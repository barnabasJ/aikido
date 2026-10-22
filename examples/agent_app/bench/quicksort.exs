defmodule AgentExamples.Quicksort.Bench.FullScanView do
  @moduledoc false
  # Frozen full-scan algorithm for measuring the previous UI against incremental presentation.

  @doc "Builds counts, depth distribution and bounded visible nodes for one subtree."
  def summarize(nodes, focus) do
    %{
      diagram: diagram_nodes(nodes, focus),
      completed: Enum.count(nodes, fn {_, node} -> node.status == :completed end),
      levels:
        nodes
        |> Map.values()
        |> Enum.frequencies_by(&(String.length(&1.branch) - 4))
        |> Enum.sort(),
      visible: visible_nodes(nodes, focus)
    }
  end

  defp visible_nodes(nodes, focus) do
    nodes
    |> Map.values()
    |> Enum.filter(&String.starts_with?(&1.branch, focus))
    |> Enum.sort_by(&{String.length(&1.branch), &1.branch})
    |> Enum.take(80)
  end

  defp diagram_nodes(nodes, focus) do
    nodes
    |> Map.values()
    |> Enum.filter(
      &(String.starts_with?(&1.branch, focus) &&
          String.length(&1.branch) <= String.length(focus) + 6)
    )
    |> Enum.sort_by(& &1.branch)
    |> Enum.map(fn node ->
      relative = String.replace_prefix(node.branch, focus, "")

      {left, width} =
        relative
        |> String.graphemes()
        |> Enum.reduce({0.0, 960.0}, fn direction, {left, width} ->
          {if(direction == "R", do: left + width / 2, else: left), width / 2}
        end)

      Map.merge(node, %{x: left + width / 2, y: 24 + String.length(relative) * 42})
    end)
  end
end

defmodule AgentExamples.Quicksort.Bench.Collector do
  @moduledoc false
  use GenServer

  def start_link({topic, expected}), do: GenServer.start_link(__MODULE__, {topic, expected})
  def finish(pid), do: GenServer.call(pid, :finish, 600_000)

  @impl true
  def init({topic, expected}) do
    :ok = Phoenix.PubSub.subscribe(AgentExamples.PubSub, topic)

    {:ok,
     %{
       nodes: %{},
       completed: 0,
       expected: expected,
       waiting: nil,
       last: nil,
       gap_us: 0,
       events: 0
     }}
  end

  @impl true
  def handle_call(:finish, from, state) do
    if state.completed == state.expected,
      do: {:reply, metrics(state), state},
      else: {:noreply, %{state | waiting: from}}
  end

  @impl true
  def handle_info({:quicksort_progress, _, node}, state) do
    now = System.monotonic_time(:microsecond)
    prior = Map.get(state.nodes, node.branch)

    completed =
      state.completed + if(node.status == :completed && prior != :completed, do: 1, else: 0)

    status = if prior == :completed, do: :completed, else: node.status

    state = %{
      state
      | nodes: Map.put(state.nodes, node.branch, status),
        completed: completed,
        last: now,
        gap_us: if(state.last, do: max(state.gap_us, now - state.last), else: 0),
        events: state.events + 1
    }

    if state.waiting && completed == state.expected do
      GenServer.reply(state.waiting, metrics(state))
      {:noreply, %{state | waiting: nil}}
    else
      {:noreply, state}
    end
  end

  defp metrics(state), do: Map.take(state, [:completed, :events, :gap_us])
end

defmodule AgentExamples.Quicksort.Bench do
  @moduledoc false
  @store AgentExamples.Quicksort.Bench.Store
  @profile [
    {Aikido.Durable.AgentServer, :dump_state, 1},
    {DurableServer.Backends.EKVStore, :get_object, 3},
    {DurableServer.Backends.EKVStore, :put_object, 4},
    {DurableServer.Backends.EKVStore, :try_claim, 3},
    {DurableServer.Backends.EKVStore, :update_object, 4}
  ]

  def run(argv) do
    Logger.configure(level: :warning)

    {opts, _, invalid} =
      OptionParser.parse(argv,
        strict: [
          quick: :boolean,
          sizes: :string,
          suite: :string,
          profile: :boolean,
          output: :string
        ]
      )

    if invalid != [], do: raise(ArgumentError, "Invalid benchmark options: #{inspect(invalid)}")
    sizes = (opts[:sizes] || "128,1024") |> String.split(",") |> Enum.map(&String.to_integer/1)

    if Enum.any?(sizes, &(&1 < 1 || &1 > 100_000)),
      do: raise(ArgumentError, "Sizes must be 1..100000")

    for app <- [:aikido, :phoenix_pubsub, :benchee], do: Application.ensure_all_started(app)
    :rand.seed(:exsss, {42, 43, 44})
    output = Path.expand(opts[:output] || "_build/quicksort-bench.jsonl")
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, "")
    settings = if opts[:quick], do: [warmup: 0, time: 0.1], else: [warmup: 1, time: 3]
    settings = settings ++ [parallel: 1, memory_time: 0, reduction_time: 0]
    suite = opts[:suite] || "all"

    if suite not in ["all", "tree", "view"],
      do: raise(ArgumentError, "--suite must be tree, view or all")

    if suite in ["all", "view"], do: benchmark_view(settings)
    if suite in ["all", "tree"], do: benchmark_trees(sizes, settings, output, opts[:profile])
    IO.puts("Per-run lifecycle metrics: #{output}")
  end

  defp benchmark_view(settings) do
    inputs =
      Map.new([1_000, 10_000, 100_000], fn size ->
        nodes =
          Map.new(1..size, fn index ->
            branch =
              "root" <>
                (index
                 |> Integer.to_string(2)
                 |> String.slice(1..-1//1)
                 |> String.replace("0", "L")
                 |> String.replace("1", "R"))

            {branch, %{branch: branch, status: :completed, count: 1, pivot: index, id: branch}}
          end)

        {"#{size} retained nodes",
         %{nodes: nodes, tree: AgentExamples.Quicksort.TreeView.from_nodes(nodes)}}
      end)

    for {_, input} <- inputs do
      previous = AgentExamples.Quicksort.Bench.FullScanView.summarize(input.nodes, "root")

      true =
        previous ==
          Map.delete(AgentExamples.Quicksort.TreeView.summarize(input.tree, "root"), :failed)
    end

    Benchee.run(
      %{
        "full scan and sort (previous UI)" => fn input ->
          AgentExamples.Quicksort.Bench.FullScanView.summarize(input.nodes, "root")
        end,
        "incremental counters + bounded branches" => fn input ->
          AgentExamples.Quicksort.TreeView.summarize(input.tree, "root")
        end
      },
      Keyword.put(settings, :inputs, inputs)
    )
  end

  defp benchmark_trees(sizes, settings, output, profile?) do
    inputs =
      for size <- sizes,
          shards <- [1, 8],
          into: %{},
          do:
            {"#{size} agents / #{shards} EKV shards",
             %{
               size: size,
               shards: shards,
               numbers: Enum.shuffle(Enum.to_list(1..size)),
               output: output
             }}

    if profile? do
      Enum.each(inputs, fn {label, input} ->
        IO.puts("Native call-time profile: #{label}")

        for {module, _, _} = mfa <- @profile do
          Code.ensure_loaded!(module)
          :erlang.trace_pattern(mfa, true, [:call_time])
        end

        :erlang.trace(:new, true, [:call])

        try do
          result = input |> start_runtime() |> sort_tree()

          IO.inspect(profile(),
            label: "Native calls (nested times are not additive)",
            limit: :infinity
          )

          stop_runtime(result)
        after
          :erlang.trace(:all, false, [:call])
          for mfa <- @profile, do: :erlang.trace_pattern(mfa, false, [:call_time])
        end
      end)
    end

    Benchee.run(
      %{"native Ash + DurableServer + EKV + notifications" => &sort_tree/1},
      settings ++ [inputs: inputs, before_each: &start_runtime/1, after_each: &stop_runtime/1]
    )
  end

  defp start_runtime(input) do
    directory =
      Path.expand("_build/quicksort-bench-#{System.pid()}-#{System.unique_integer([:positive])}")

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {EKV,
           name: @store,
           data_dir: directory,
           cluster_size: 1,
           node_id: "bench",
           shards: input.shards},
          {Aikido,
           max_tasks: 20_000, durable: [backend: {DurableServer.Backends.EKVStore, name: @store}]},
          {Phoenix.PubSub, name: AgentExamples.PubSub},
          AgentExamples.Quicksort.RunHistory
        ],
        strategy: :one_for_one
      )

    topic = "sort-bench:" <> Ash.UUIDv7.generate()
    AgentExamples.Quicksort.RunHistory.open(topic)
    {:ok, collector} = AgentExamples.Quicksort.Bench.Collector.start_link({topic, input.size})
    {activation_us, root} = :timer.tc(fn -> AgentExamples.Agents.quicksort_start!(%{}) end)

    Map.merge(input, %{
      directory: directory,
      supervisor: supervisor,
      collector: collector,
      topic: topic,
      root: root,
      activation_us: activation_us
    })
  end

  defp sort_tree(input) do
    signal =
      AgentExamples.Quicksort.Signals.Sort.new!(%{numbers: input.numbers, topic: input.topic})

    {sort_us, {:ok, sorted}} =
      :timer.tc(fn ->
        Aikido.AgentServer.call_until(
          input.root.pid,
          signal,
          "quicksort.**",
          fn runtime ->
            state = runtime.agent.state.state
            if state.status == :completed, do: {:ok, state.result}, else: :skip
          end,
          timeout: 600_000
        )
      end)

    true = sorted == Enum.to_list(1..input.size)
    metrics = AgentExamples.Quicksort.Bench.Collector.finish(input.collector)
    Map.merge(input, %{sort_us: sort_us, notifications: metrics})
  end

  defp stop_runtime(input) do
    storage = storage_metrics(input.directory)
    members = Aikido.Durable.members(Aikido.durable_supervisor_name(Aikido.Default))
    true = length(members) in 1..input.size
    monitors = MapSet.new(Enum.map(members, fn {_, pid} -> Process.monitor(pid) end))

    {cleanup_us, :ok} =
      :timer.tc(fn ->
        AgentExamples.Agents.quicksort_stop!(input.root)
        await_down(monitors, System.monotonic_time(:millisecond) + 300_000)
      end)

    [] =
      Aikido.Durable.members(Aikido.durable_supervisor_name(Aikido.Default))
      |> Enum.filter(fn {_, pid} -> Process.alive?(pid) end)

    report = %{
      size: input.size,
      shards: input.shards,
      activation_us: input.activation_us,
      sort_us: input.sort_us,
      cleanup_us: cleanup_us,
      leftover_agents: 0,
      live_agents_at_completion: length(members),
      storage: storage,
      notifications: input.notifications,
      vm_memory_bytes: :erlang.memory(:total)
    }

    File.write!(input.output, Jason.encode!(report) <> "\n", [:append])
    GenServer.stop(input.collector)
    Supervisor.stop(input.supervisor)
    File.rm_rf!(input.directory)
    input
  end

  defp storage_metrics(directory) do
    config =
      DurableServer.Supervisor.__get_config__(Aikido.durable_supervisor_name(Aikido.Default))

    records =
      DurableServer.StorageBackend.list_all_objects_stream(config.storage_backend, config.prefix,
        include_objects: true
      )

    logical =
      Enum.reduce(records, %{records: 0, payload_bytes: 0, record_term_bytes: 0}, fn
        %{body: %DurableServer.StoredState{state: %{"payload" => payload}} = record}, total ->
          %{
            records: total.records + 1,
            payload_bytes: total.payload_bytes + byte_size(payload),
            record_term_bytes:
              total.record_term_bytes +
                :erlang.external_size(DurableServer.StoredState.to_storage_term(record))
          }

        _, total ->
          total
      end)

    files = directory |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1)

    wal_bytes =
      files
      |> Enum.filter(&String.ends_with?(&1, "-wal"))
      |> Enum.map(&File.stat!(&1).size)
      |> Enum.sum()

    Map.merge(logical, %{
      wal_bytes_at_completion: wal_bytes,
      sqlite_files_bytes: files |> Enum.map(&File.stat!(&1).size) |> Enum.sum()
    })
  end

  defp await_down(monitors, deadline) do
    if MapSet.size(monitors) == 0 do
      :ok
    else
      receive do
        {:DOWN, ref, :process, _, _} -> await_down(MapSet.delete(monitors, ref), deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          raise "Cleanup left #{MapSet.size(monitors)} monitored agents running"
      end
    end
  end

  defp profile do
    Map.new(@profile, fn mfa ->
      {:call_time, entries} = :erlang.trace_info(mfa, :call_time)

      totals =
        Enum.reduce(entries, %{calls: 0, microseconds: 0}, fn {_, count, seconds, micros},
                                                              total ->
          %{
            calls: total.calls + count,
            microseconds: total.microseconds + seconds * 1_000_000 + micros
          }
        end)

      {inspect(mfa), totals}
    end)
  end
end

AgentExamples.Quicksort.Bench.run(System.argv())
