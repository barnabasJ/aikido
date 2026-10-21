defmodule Aikido.AiReact.Actions.Stream do
  @moduledoc "Accumulates streaming text and thinking while rejecting obsolete turns and attempts."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.Preparation

  @impl true
  def run(input, _opts, _context) do
    input |> reduce() |> Preparation.finish(input)
  end

  defp reduce(input) do
    data = input.arguments
    state = data.state

    if state.status == :running && is_nil(Map.get(state, :handoff_pending)) &&
         state.request_id == data.request_id &&
         state.iteration + 1 == data.iteration &&
         data.attempt >= Map.get(state, :stream_attempt, 0) do
      reset? = data.attempt > Map.get(state, :stream_attempt, 0)

      state =
        Map.merge(state, %{
          stream_attempt: data.attempt,
          streaming_text:
            if(reset?, do: "", else: Map.get(state, :streaming_text, "")) <> data.text,
          streaming_thinking:
            if(reset?, do: "", else: Map.get(state, :streaming_thinking, "")) <> data.thinking
        })

      Aikido.Types.ActionResult.new(state: state)
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end
end
