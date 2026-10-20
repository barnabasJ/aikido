defmodule AgentExamples.Worker.Work do
  @moduledoc "Marks the worker busy and returns a directive for the uppercase task."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state

    if state.status == :working do
      {:error, "Worker is already busy"}
    else
      directive =
        Aikido.Directives.async_task({AgentExamples.Worker, :uppercase, [input.arguments.text]},
          success_type: "worker.completed",
          error_type: "worker.failed"
        )

      Aikido.Types.ActionResult.new(
        state: %{state | status: :working, result: nil, error: nil},
        directives: [directive]
      )
    end
  end
end
