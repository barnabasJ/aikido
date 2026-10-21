defmodule Aikido.AiReact.Actions.Deliver do
  @moduledoc """
  Adds incoming text to this AI agent's conversation, such as a worker's task result.

  While the agent is setting up or working, queues the text for its next model
  request and records the incoming message's request ID and metadata. Otherwise,
  starts a new run with that text, request ID and metadata. Incoming messages
  must respect the active run's actor and tenant.
  """
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{HookQueue, RunState, RunCaller}

  @impl true
  def run(input, _opts, _context) do
    with :ok <- RunCaller.validate_run_caller(input.arguments.state, input) do
      if input.arguments.state.status in [:setup, :running] do
        queue_incoming_conversation_text(input)
      else
        start_run_from_incoming_text(input)
      end
    end
  end

  defp queue_incoming_conversation_text(input) do
    input.arguments.state
    |> queue_text_for_next_model_request(input.arguments.text)
    |> record_incoming_message_metadata(input.arguments)
    |> then(&Aikido.Types.ActionResult.new(state: &1))
  end

  defp queue_text_for_next_model_request(state, text) do
    Map.update(state, :queued_messages, [text], &(&1 ++ [text]))
  end

  defp record_incoming_message_metadata(state, arguments) do
    message = Map.take(arguments, [:request_id, :metadata])

    Map.update(state, :run_metadata, %{}, fn metadata ->
      Map.update(metadata, :deliveries, [message], &(&1 ++ [message]))
    end)
  end

  defp start_run_from_incoming_text(input) do
    with {:ok, result} <-
           RunState.begin_run(
             %{
               query: input.arguments.text,
               request_id: input.arguments.request_id,
               metadata: input.arguments.metadata
             },
             input.arguments.state
           ) do
      {:ok, result}
      |> RunCaller.bind_run_caller(input)
      |> HookQueue.queue_event_hooks(:run_started, %{query: input.arguments.text})
    end
  end
end
