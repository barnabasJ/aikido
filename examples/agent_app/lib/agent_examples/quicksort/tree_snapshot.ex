defmodule AgentExamples.Quicksort.TreeSnapshot do
  @moduledoc "Reads a retained agent tree once when a browser reconnects; ongoing updates use notifications."

  def read(pid) do
    case Aikido.AgentServer.state(pid, &{:ok, partition_snapshot(&1)}) do
      {:ok, {node, children}} ->
        Enum.reduce(children, %{node.branch => node}, fn child, nodes ->
          Map.merge(nodes, read(child))
        end)

      {:error, _} ->
        %{}
    end
  catch
    :exit, _ -> %{}
  end

  defp partition_snapshot(runtime) do
    state = runtime.agent.state.state

    node = %{
      branch: state.branch,
      id: runtime.id,
      status: state.status,
      count: length(state.numbers),
      pivot: state.pivot
    }

    children = Enum.map(runtime.children, fn {_, child} -> child.pid end)
    {node, children}
  end
end
