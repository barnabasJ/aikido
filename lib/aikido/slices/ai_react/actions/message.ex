defmodule Aikido.Slices.AiReact.Actions.Message do
  @moduledoc "Queues a message or resumes a waiting run within its bound caller scope."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Slices.AiReact.{Hooks, Preparation, Run, Scope}

  @impl true
  def run(input, _opts, _context) do
    result =
      with :ok <- Scope.validate(input.arguments.state, input) do
        reduce(input)
      end

    Preparation.finish(result, input)
  end

  defp reduce(input) do
    state = input.arguments.state

    if state.status == :waiting do
      case Run.open(
             %{
               query: input.arguments.text,
               request_id: state.request_id,
               metadata: Map.get(state, :run_metadata, %{})
             },
             state
           ) do
        {:ok, result} ->
          Hooks.transition(
            Scope.bind({:ok, result}, input),
            :run_started,
            %{
              query: input.arguments.text
            }
          )

        error ->
          error
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
