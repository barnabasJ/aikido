defmodule Aikido.Team.Actions.Started do
  @moduledoc "Adopts a correlated member activation and advances the lifecycle plan, cleaning up late activations."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, TopologyOperation}
  alias Aikido.Directives

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = ActionAdapter.unpack_team_action(input)

    ActionAdapter.to_action_result(
      adopt_started_member(signal.data, state, context, config),
      state
    )
  end

  defp adopt_started_member(
         %{member: name, operation_id: id, result: pid} = data,
         state,
         context,
         config
       ) do
    if TopologyOperation.awaited?(state, id, {:start, name}) do
      state
      |> record_activation(name, id, pid)
      |> advance_after_activation(data, context, config)
    else
      cleanup_late_activation(state, pid, config)
    end
  end

  defp record_activation(state, name, id, pid) do
    state = %{
      state
      | members: Map.put(state.members, name, pid),
        incarnations: Map.put(state.incarnations, name, id)
    }

    update_in(state.operation.started, &(&1 ++ [name]))
  end

  defp advance_after_activation(
         state,
         %{member: name, operation_id: id, result: pid},
         context,
         config
       ) do
    case state.failures[name] do
      %{pid: ^pid, reason: reason} ->
        state = %{
          state
          | members: Map.delete(state.members, name),
            incarnations: Map.delete(state.incarnations, name)
        }

        TopologyOperation.fail_operation_and_pending_tasks(
          %{operation_id: id, reason: {:member_exited, name, reason}},
          state,
          context
        )

      _ ->
        TopologyOperation.advance_member_lifecycle(state, context, config)
    end
  end

  defp cleanup_late_activation(state, pid, config) do
    # A timed-out activation must not leave an untracked worker running.
    instance = config.instance

    directives =
      if pid in Map.values(state.members),
        do: [],
        else: [
          Directives.async_task(
            fn task ->
              Aikido.Team.MemberProcesses.stop_member(instance, pid, task.input_signal)
            end,
            success_type: "aikido.ash.team.cleanup",
            error_type: "aikido.ash.team.cleanup"
          )
        ]

    {:ok, state, directives}
  end
end
