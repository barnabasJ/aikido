defmodule AgentExamples.Quicksort.Bench.StorageTrace do
  @moduledoc "Wall-clock BEAM traces of native EKV maintenance; arguments and results are discarded."
  @operations [
    {EKV.Store, :find_expired, 2},
    {EKV.Store, :purge_expired, 2},
    {EKV.Store, :purge_tombstones, 2},
    {EKV.Store, :purge_orphan_paxos, 1},
    {EKV.Store, :purge_orphan_keyrefs, 1},
    {EKV.Store, :truncate_oplog_batch, 3}
  ]

  def start(output) do
    tracer = spawn_link(fn -> collect(%{}, [], output) end)
    Code.ensure_loaded!(EKV.Store)

    for operation <- @operations do
      :erlang.trace_pattern(operation, [{:_, [], [{:return_trace}]}], [:local])
    end

    :erlang.trace(:all, true, [:call, :monotonic_timestamp, {:tracer, tracer}])
    :erlang.trace(:new, true, [:call, :monotonic_timestamp, {:tracer, tracer}])
    tracer
  end

  def finish(tracer, output) do
    :erlang.trace(:all, false, [:call])
    :erlang.trace(:new, false, [:call])
    for operation <- @operations, do: :erlang.trace_pattern(operation, false, [:local])
    ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    after
      5000 -> raise "EKV maintenance trace did not drain"
    end

    send(tracer, {:finish, self()})

    receive do
      {:storage_spans, ^tracer, spans} ->
        File.write!(output <> ".storage-spans.json", Jason.encode!(spans))
    after
      5000 -> raise "EKV maintenance trace did not finish"
    end
  end

  defp collect(stacks, spans, output) do
    receive do
      {:trace_ts, pid, :call, {module, function, args}, timestamp} ->
        operation = {module, function, length(args)}
        frame = {operation, timestamp}

        started = %{
          operation: inspect(operation),
          pid: inspect(pid),
          started_monotonic_ms: System.convert_time_unit(timestamp, :native, :millisecond)
        }

        File.write!(output <> ".storage-starts.jsonl", Jason.encode!(started) <> "\n", [:append])
        collect(Map.update(stacks, pid, [frame], &[frame | &1]), spans, output)

      {:trace_ts, pid, :return_from, operation, _result, timestamp} ->
        case Map.get(stacks, pid, []) do
          [{^operation, started} | rest] ->
            span = %{
              operation: inspect(operation),
              pid: inspect(pid),
              elapsed_ms:
                System.convert_time_unit(timestamp - started, :native, :microsecond) / 1000,
              finished_monotonic_ms: System.convert_time_unit(timestamp, :native, :millisecond)
            }

            File.write!(output <> ".storage-spans.jsonl", Jason.encode!(span) <> "\n", [:append])
            collect(Map.put(stacks, pid, rest), [span | spans], output)

          _ ->
            collect(stacks, spans, output)
        end

      {:finish, from} ->
        send(from, {:storage_spans, self(), Enum.reverse(spans)})
    end
  end
end
