defmodule AgentExamples.Worker.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, [action: :work], _context) do
    state = input.arguments.state

    if state.status == :working do
      {:error, "Worker is already busy"}
    else
      directive =
        Aikido.Directives.async_task({AgentExamples.Worker, :uppercase, [input.arguments.text]},
          success_type: "worker.completed",
          error_type: "worker.failed"
        )

      Aikido.ActionResult.new(
        state: %{state | status: :working, result: nil, error: nil},
        directives: [directive]
      )
    end
  end

  @impl true
  def run(input, [action: :completed], _context) do
    Aikido.ActionResult.new(
      state: %{input.arguments.state | status: :completed, result: input.arguments.result}
    )
  end

  @impl true
  def run(input, [action: :failed], _context) do
    Aikido.ActionResult.new(
      state: %{input.arguments.state | status: :failed, error: input.arguments.reason}
    )
  end
end
