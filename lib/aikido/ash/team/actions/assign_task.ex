defmodule Aikido.Ash.Team.Actions.AssignTask do
  @moduledoc "Tracks a task and dispatches it to its member, activating a lazy member when needed."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Ash.Team.{Inputs, Tasks}
  alias Aikido.Directives
  alias Aikido.Signal

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.read(input)
    Inputs.result(reduce(signal, state, context, config))
  end

  defp reduce(signal, state, context, config) do
    id = signal.data[:task_id] || signal.id

    cond do
      Map.has_key?(state.tasks, id) ->
        {:error, {:task_exists, id}}

      Map.has_key?(state.members, signal.data.member) ->
        state = Map.update(state, :pending_tasks, %{}, &Map.delete(&1, id))
        assign_task(signal, state, context)

      Map.has_key?(Map.get(state, :pending_tasks, %{}), id) ->
        {:error, :operation_in_progress}

      Map.has_key?(state.topology.nodes, signal.data.member) ->
        state =
          Map.update(state, :pending_tasks, %{id => signal.data}, &Map.put(&1, id, signal.data))

        Aikido.Ash.Team.Actions.EnsureMember.reduce(
          %{signal | data: %{member: signal.data.member}},
          state,
          context,
          config
        )

      true ->
        {:error, {:unknown_member, signal.data.member}}
    end
  end

  defp assign_task(signal, state, context) do
    data = signal.data
    id = Map.get(data, :task_id) || signal.id

    with true <- !Map.has_key?(state.tasks, id) || {:error, {:task_exists, id}},
         {:ok, pid} <- Tasks.fetch_member(state, data.member) do
      outgoing =
        %Signal{
          id: nil,
          type: Map.get(data, :type, "harness.task"),
          data:
            Map.merge(Map.get(data, :payload, %{}), %{
              metadata: data[:metadata] || %{},
              task_id: id,
              member: data.member,
              reply_to: context.agent_pid,
              attempt: state.incarnations[data.member]
            }),
          source: "/ash/team"
        }

      task = %{
        id: id,
        member: data.member,
        status: :dispatched,
        result: nil,
        notify: data[:notify],
        metadata: data[:metadata] || %{},
        attempt: state.incarnations[data.member]
      }

      effects = [Directives.emit_to_pid(outgoing, pid)]
      timeout = Map.get(data, :timeout_ms, 30_000)

      effects =
        if is_integer(timeout) && timeout > 0,
          do:
            effects ++
              [
                Directives.schedule(
                  timeout,
                  %Signal{
                    id: nil,
                    type: "aikido.ash.team.task.timeout",
                    data: %{
                      task_id: id,
                      attempt: task.attempt
                    },
                    source: "/aikido"
                  }
                )
              ],
          else: effects

      {:ok, put_in(state.tasks[id], task), effects}
    end
  end
end
