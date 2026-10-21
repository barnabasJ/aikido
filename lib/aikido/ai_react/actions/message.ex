defmodule Aikido.AiReact.Actions.Message do
  @moduledoc "Queues a message or resumes a waiting run within its bound caller scope."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Hooks, Run, Scope}

  @impl true
  def run(input, _opts, _context) do
    with :ok <- Scope.validate_run_caller(input.arguments.state, input) do
      queue_message_or_resume_run(input)
    end
  end

  defp queue_message_or_resume_run(input) do
    state = input.arguments.state

    if state.status == :waiting do
      with {:ok, result} <-
             Run.begin_run(
               %{
                 query: input.arguments.text,
                 request_id: state.request_id,
                 metadata: Map.get(state, :run_metadata, %{})
               },
               state
             ) do
        {:ok, result}
        |> Scope.bind_run_caller(input)
        |> Hooks.queue_event_hooks(:run_started, %{query: input.arguments.text})
      end
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
