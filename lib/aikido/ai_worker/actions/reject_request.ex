defmodule Aikido.AiWorker.Actions.RejectRequest do
  @moduledoc "Settles a rejected inner request only before its matching AI run was adopted."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, _context) do
    state = input.arguments.state
    context = input.context.aikido
    data = input.arguments
    ai = context.agent.state.ai

    case state.pending do
      %{task_id: id, member: member, attempt: attempt} = pending
      when id == data.task_id and member == data.member and attempt == data.attempt and
             ai.request_id != id ->
        error = Aikido.AiWorker.Errors.RequestRejected.exception(failure: data.failure)

        with {:ok, next, directives} <-
               Aikido.AiWorker.Actions.Settle.report_task_outcome_and_start_next(
                 state,
                 pending,
                 :failed,
                 error,
                 context
               ) do
          Aikido.Types.ActionResult.new(
            changes: Map.take(next, [:queue, :pending, :completed]),
            directives: directives
          )
        end

      _stale_or_adopted ->
        Aikido.Types.ActionResult.new(changes: nil)
    end
  end
end
