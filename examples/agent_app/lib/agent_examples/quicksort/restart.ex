defmodule AgentExamples.Quicksort.Restart do
  @moduledoc "Restarts a browser's sorting example after the previous tree has terminated."

  @doc """
  Stops the old tree, awaits its processes, then checkpoints native EKV before
  starting the replacement root. This external operation runs outside agents.
  """
  def restart(owner, timeout \\ 300_000) do
    run = AgentExamples.Playground.get(owner, "quicksort")
    monitors = monitor_tree(run)
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      with :ok <- AgentExamples.Playground.stop(owner, "quicksort"),
           :ok <- stop_surviving_tree_processes(monitors),
           :ok <- await_tree_exit(monitors, deadline),
           :ok <- checkpoint_agent_store() do
        AgentExamples.Playground.start(owner, "quicksort", %{})
      end
    after
      for ref <- Map.keys(monitors), do: Process.demonitor(ref, [:flush])
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

  defp monitor_tree(%{record: %{id: root_id}}) do
    Aikido.Default
    |> Aikido.durable_supervisor_name()
    |> Aikido.Durable.members()
    |> Enum.filter(fn {id, _pid} -> id == root_id || String.starts_with?(id, root_id <> "/") end)
    |> Map.new(fn {_id, pid} -> {Process.monitor(pid), pid} end)
  end

  defp monitor_tree(_), do: %{}

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
