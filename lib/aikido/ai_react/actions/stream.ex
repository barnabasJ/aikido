defmodule Aikido.AiReact.Actions.Stream do
  @moduledoc "Accumulates streaming text and thinking while rejecting obsolete turns and attempts."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    with {:ok, state, directives} <- append_stream_chunk(input) do
      changes =
        if state == input.arguments.state,
          do: %{},
          else: Map.take(state, [:stream_attempt, :streaming_text, :streaming_thinking])

      Aikido.Types.ActionResult.new(changes: changes, directives: directives)
    end
  end

  defp append_stream_chunk(input) do
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

      {:ok, state, []}
    else
      {:ok, state, []}
    end
  end
end
