defmodule AgentExamples.Quicksort.Restart do
  @moduledoc "Restarts a browser's sorting example after the previous tree has terminated."

  @doc "Monitors the old tree before stopping its root, then starts a fresh root after teardown."
  def restart(owner, timeout \\ 300_000) do
    run = AgentExamples.Playground.get(owner, "quicksort")
    monitors = monitor_tree(run)
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      with :ok <- AgentExamples.Playground.stop(owner, "quicksort"),
           :ok <- await_tree_exit(monitors, deadline) do
        AgentExamples.Playground.start(owner, "quicksort", %{})
      end
    after
      for ref <- Map.keys(monitors), do: Process.demonitor(ref, [:flush])
    end
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
