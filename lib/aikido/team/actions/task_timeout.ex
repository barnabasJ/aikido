defmodule Aikido.Team.Actions.TaskTimeout do
  @moduledoc "Fails a correlated task on timeout and returns cancellation and notification directives."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{Inputs, Tasks}
  alias Aikido.Directives
  alias Aikido.Signal

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.read(input)
    Inputs.result(expire_task_and_request_cancellation(signal.data, state, context, config))
  end

  defp expire_task_and_request_cancellation(data, state, context, _config) do
    case Map.get(state.tasks, data.task_id) do
      %{status: :dispatched, attempt: attempt} = task when attempt == data.attempt ->
        task = %{task | status: :failed, result: :timeout}
        state = put_in(state.tasks[data.task_id], task)

        cancel =
          case state.members[task.member] do
            nil ->
              []

            pid ->
              [
                Directives.emit_to_pid(
                  %Signal{
                    id: nil,
                    type: "harness.cancel_task",
                    data: %{task_id: task.id},
                    source: "/aikido"
                  },
                  pid
                )
              ]
          end

        {:ok, state, cancel ++ Tasks.notification_directives(task, state, context)}

      _ ->
        {:ok, state, []}
    end
  end
end
