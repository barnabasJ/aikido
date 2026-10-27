defmodule AgentExamples.Quicksort.Restart do
  @moduledoc "Restarts a browser's sorting example after the previous tree has terminated."

  @doc """
  Stops the old tree, awaits its processes, then checkpoints native EKV before
  starting the replacement root. This external operation runs outside agents.
  """
  def restart(owner, timeout \\ 300_000) do
    run = AgentExamples.Playground.get(owner, "quicksort")
    members = tree_members(run)
    monitors = Map.new(members, fn {_id, pid} -> {Process.monitor(pid), pid} end)
    identities = tree_identities(run, members)
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      with :ok <- AgentExamples.Playground.stop(owner, "quicksort"),
           :ok <- stop_surviving_tree_processes(monitors),
           :ok <- await_tree_exit(monitors, deadline),
           :ok <- delete_saved_tree(identities),
           :ok <- checkpoint_agent_store() do
        AgentExamples.Playground.start(owner, "quicksort", %{})
      end
    after
      for ref <- Map.keys(monitors), do: Process.demonitor(ref, [:flush])
    end
  end

  # Read known identities directly instead of enumerating the entire durable store.
  # Reconstructing the deterministic partition paths also covers a worker that
  # crashed before its first UI notification, or a lost display history.
  defp tree_identities(%{record: %{id: root_id}, snapshot: %{own: state}}, members) do
    recorded =
      case AgentExamples.Quicksort.RunHistory.fetch(state.topic) do
        {:ok, tree} -> Enum.map(tree.nodes, fn {_, node} -> node.id end)
        :error -> []
      end

    (partition_identities(root_id, partition_numbers(root_id)) ++
       recorded ++ Enum.map(members, &elem(&1, 0)))
    |> Enum.uniq()
    |> Enum.filter(&(&1 == root_id || String.starts_with?(&1, root_id <> "/")))
  end

  defp tree_identities(_, _), do: []

  defp partition_numbers(root_id) do
    pool = Aikido.durable_supervisor_name(Aikido.Default)

    with {:ok, pid} <- Aikido.Durable.lookup(pool, root_id),
         {:ok, numbers} <- Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.state.numbers}) do
      numbers
    else
      _ -> []
    end
  end

  defp partition_identities(id, numbers) do
    {_pivot, _equal, partitions} = AgentExamples.Quicksort.PartitionTree.split(numbers)

    [
      id
      | Enum.flat_map(partitions, fn {branch, values} ->
          partition_identities(Aikido.Agent.child_id(id, branch), values)
        end)
    ]
  end

  defp delete_saved_tree(identities) do
    pool = Aikido.durable_supervisor_name(Aikido.Default)

    identities
    |> Task.async_stream(
      &delete_partition_checkpoint(pool, &1),
      max_concurrency: 8,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, :ok}, :ok ->
        {:cont, :ok}

      {:ok, {:error, reason}}, :ok when reason in [:not_found, :different_resource] ->
        # An uncreated partition can have a native reservation without agent data.
        # Resource validation also protects non-Quicksort identities at these paths.
        {:cont, :ok}

      {:ok, {:error, reason}}, :ok ->
        {:halt, {:error, reason}}

      {:exit, reason}, :ok ->
        {:halt, {:error, reason}}
    end)
  end

  defp delete_partition_checkpoint(pool, id) do
    case Aikido.Durable.delete(pool, id, agent: AgentExamples.Quicksort) do
      {:error, :noproc} ->
        # A clean stop can win between native lookup and deletion. Resolve the
        # stable key again to delete any remaining checkpoint, or confirm absence.
        Aikido.Durable.delete(pool, id, agent: AgentExamples.Quicksort)

      result ->
        result
    end
  end

  # Recovery can replace parents without reconstructing their old live child
  # monitors. Retire every process in this tree, including detached descendants.
  defp stop_surviving_tree_processes(monitors) do
    Enum.reduce_while(monitors, :ok, fn {_ref, pid}, :ok ->
      if Process.alive?(pid) do
        case AgentExamples.Agents.quicksort_stop(pid) do
          {:ok, _} ->
            {:cont, :ok}

          {:error, reason} ->
            if Process.alive?(pid), do: {:halt, {:error, reason}}, else: {:cont, :ok}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  # A fully checkpointed WAL can be reused by the next writer. Background passive
  # checkpoints can remain behind continuous partition writes across immediate runs.
  defp checkpoint_agent_store do
    store = Application.fetch_env!(:agent_examples, :store)
    name = Keyword.fetch!(store, :name)

    Enum.reduce_while(0..(Keyword.fetch!(store, :shards) - 1), :ok, fn shard, :ok ->
      case EKV.WALCheckpointer.checkpoint(name, shard) do
        {:ok, _stats} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:checkpoint_failed, shard, reason}}}
      end
    end)
  end

  defp tree_members(%{record: %{id: root_id}}) do
    Aikido.Default
    |> Aikido.durable_supervisor_name()
    |> Aikido.Durable.members()
    |> Enum.filter(fn {id, _pid} -> id == root_id || String.starts_with?(id, root_id <> "/") end)
  end

  defp tree_members(_), do: []

  defp await_tree_exit(monitors, _deadline) when map_size(monitors) == 0, do: :ok

  defp await_tree_exit(monitors, deadline) do
    receive do
      {:DOWN, ref, :process, _pid, _reason} when is_map_key(monitors, ref) ->
        await_tree_exit(Map.delete(monitors, ref), deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        {:error, "The previous sorting tree is still stopping. Try restarting again."}
    end
  end
end
