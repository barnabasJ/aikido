defmodule AgentExamples.Quicksort.PartitionTree do
  @moduledoc "Pure partitioning, child descriptors and result assembly for recursive quicksort."

  def split(numbers) do
    pivot = Enum.at(numbers, div(length(numbers), 2))

    groups =
      Enum.group_by(numbers, fn number ->
        cond do
          number < pivot -> "L"
          number > pivot -> "R"
          true -> "equal"
        end
      end)

    {pivot, Map.get(groups, "equal", []), Map.take(groups, ["L", "R"])}
  end

  def spawn_partitions(state) do
    Enum.map(state.partitions, fn {branch, _numbers} ->
      %Aikido.Directives.SpawnAgent{
        agent: AgentExamples.Quicksort,
        tag: branch,
        restart?: false,
        opts: %{initial_state: %{branch: state.branch <> branch}, on_parent_death: :stop}
      }
    end)
  end

  def finish_or_wait(state, context) do
    if map_size(state.results) == map_size(state.partitions) do
      result = Map.get(state.results, "L", []) ++ state.equal ++ Map.get(state.results, "R", [])
      state = %{state | status: :completed, result: result}

      Aikido.Types.ActionResult.new(
        state: state,
        directives: [progress(state, context) | reply_to_parent(state, context)]
      )
    else
      Aikido.Types.ActionResult.new(state: state, directives: [progress(state, context)])
    end
  end

  def progress(state, context) do
    AgentExamples.Quicksort.Progress.notification(state.topic, %{
      branch: state.branch,
      id: context.agent_id,
      status: state.status,
      count: length(state.numbers),
      pivot: state.pivot
    })
  end

  defp reply_to_parent(state, %{parent: %Aikido.AgentServer.ParentRef{pid: pid, tag: branch}}) do
    [
      %Aikido.Directives.Emit{
        target: pid,
        signal: %Aikido.Signal{
          type: "quicksort.sorted",
          source: "/examples/quicksort",
          data: %{branch: branch, numbers: state.result}
        }
      }
    ]
  end

  defp reply_to_parent(_state, _context), do: []
end
