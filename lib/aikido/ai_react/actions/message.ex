defmodule Aikido.AiReact.Actions.Message do
  @moduledoc "Queues a message or resumes a waiting run within its bound caller scope."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{RunState, RunCaller}

  @impl true
  def run(input, _opts, _context) do
    with {:ok, state, directives} <- process_incoming_message(input) do
      changes =
        if state == input.arguments.state,
          do: %{},
          else: Map.take(state, Enum.map(Ash.Resource.Info.attributes(input.resource), & &1.name))

      Aikido.Types.ActionResult.new(changes: changes, directives: directives)
    end
  end

  defp process_incoming_message(input) do
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

      {:ok, state, []}
    end
  end
end
