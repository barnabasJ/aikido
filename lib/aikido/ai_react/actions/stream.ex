defmodule Aikido.AiReact.Actions.Stream do
  @moduledoc "Adopts ordered streaming batches while rejecting obsolete turns and attempts."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    data = input.arguments

    changes =
      if Aikido.AiReact.StreamDelivery.active?(state, data) && accepts_sequence?(state, data) do
        reset? = data.attempt > state.stream_attempt

        %{
          stream_attempt: data.attempt,
          stream_receipt: receipt(data),
          streaming_text: if(reset?, do: data.text, else: state.streaming_text <> data.text),
          streaming_thinking:
            if(reset?, do: data.thinking, else: state.streaming_thinking <> data.thinking)
        }
      else
        %{}
      end

    Aikido.Types.ActionResult.new(changes: changes)
  end

  defp accepts_sequence?(_state, %{sequence: nil}), do: true

  defp accepts_sequence?(state, data) do
    case state.stream_receipt do
      %{request_id: request, iteration: iteration, attempt: attempt, sequence: sequence}
      when request == data.request_id and iteration == data.iteration and attempt == data.attempt ->
        data.sequence == sequence + 1

      _ ->
        data.sequence == 1
    end
  end

  defp receipt(%{sequence: nil}), do: nil
  defp receipt(data), do: Map.take(data, [:request_id, :iteration, :attempt, :sequence])
end
