defmodule AgentExamples.Quicksort.PartitionTree do
  @moduledoc "Pure partitioning, child descriptors and result assembly for recursive quicksort."

  def split(numbers) do
    pivot = pivot(numbers)

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

  @doc "Selects the middle value as the pivot for a nonempty partition."
  def pivot(numbers), do: Enum.at(numbers, div(length(numbers), 2))

  def spawn_partitions(state) do
    Enum.map(state.partitions, fn {branch, _numbers} -> spawn_partition(state, branch) end)
  end

  @doc "Spawns a partition using the runtime's deterministic parent-ID/branch-name identity."
  def spawn_partition(state, branch) do
    %Aikido.Directives.SpawnAgent{
      agent: AgentExamples.Quicksort,
      tag: branch,
      restart?: false,
      start_options: [timeout: 30_000],
      opts: %{
        initial_state: %{branch: state.branch <> branch},
        on_parent_death: :stop
      }
    }
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

  defp reply_to_parent(state, %{parent: %Aikido.Ownership.ParentRef{pid: pid, tag: branch}}) do
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
  @doc "Records an unrecoverable pending partition failure and notifies its parent."
  def fail_partition(state, data, context) do
    branch = Map.get(data, :branch, data[:tag])

    if state.status == :sorting && Map.has_key?(state.partitions, branch) &&
         !Map.has_key?(state.results, branch) do
      state = %{
        state
        | status: :failed,
          error: %{branch: branch, child_id: Map.get(data, :child_id), reason: data.reason}
      }

      notify = AgentExamples.Quicksort.PartitionTree.progress(state, context)

      replies =
        case context[:parent] do
          %Aikido.Ownership.ParentRef{pid: pid, tag: tag} ->
            [
              %Aikido.Directives.Emit{
                target: pid,
                signal: %Aikido.Signal{
                  type: "quicksort.failed",
                  source: "/examples/quicksort",
                  data: %{branch: tag, reason: state.error}
                }
              }
            ]

          _ ->
            []
        end

      Aikido.Types.ActionResult.new(state: state, directives: [notify | replies])
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end
end
