defmodule Aikido.AiReact.Actions.Message do
  @moduledoc "Queues a message or resumes a waiting run within its bound caller scope."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{RunState, RunCaller}

  @impl true
  def run(input, _opts, _context) do
    with :ok <- RunCaller.validate_run_caller(input.arguments.state, input) do
      queue_message_or_resume_run(input)
    end
  end

  defp queue_message_or_resume_run(input) do
    state = input.arguments.state

    if state.status == :waiting do
      RunState.resume_waiting_run(state, input.arguments.text)
    else
      state =
        Map.update(
          state,
          :queued_messages,
          [input.arguments.text],
          &(&1 ++ [input.arguments.text])
        )

      Aikido.Types.ActionResult.new(state: state)
    end
  end
end
