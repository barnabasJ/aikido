defmodule Aikido.AiReact.Actions.Deliver do
  @moduledoc """
  Adds incoming text to this AI agent's conversation, such as a worker's task result.

  While the agent is setting up or working, queues the text for its next model
  request and records the incoming message's request ID and metadata. Otherwise,
  starts a new run with that text, request ID and metadata. Incoming messages
  must respect the active run's actor and tenant.

  A successfully accepted request ID is retained for the agent's lifetime.
  Repeating that delivery does not append text or start another model run,
  including after a checkpoint is restored. Authorization still runs first.
  """
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{HookQueue, RunState, RunCaller, UserMessage}

  @impl true
  def run(input, _opts, _context) do
    with {:ok, state, directives} <- accept_incoming_delivery(input) do
      changes =
        if state == input.arguments.state,
          do: %{},
          else: Map.take(state, Enum.map(Ash.Resource.Info.attributes(input.resource), & &1.name))

      Aikido.Types.ActionResult.new(changes: changes, directives: directives)
    end
  end

  defp accept_incoming_delivery(input) do
    with :ok <- RunCaller.validate_run_caller(input.arguments.state, input) do
      if input.arguments.request_id in input.arguments.state.accepted_delivery_ids do
        {:ok, input.arguments.state, []}
      else
        accept_new_delivery(input)
      end
    end
  end

  defp accept_new_delivery(input) do
    result =
      case input.arguments.state.status do
        status when status in [:setup, :running] -> queue_incoming_conversation_text(input)
        :waiting -> resume_waiting_conversation(input)
        _ -> start_run_from_incoming_text(input)
      end

    with {:ok, state, directives} <- validate_incoming_todo_mount(result, input) do
      accepted = [input.arguments.request_id | state.accepted_delivery_ids]
      {:ok, %{state | accepted_delivery_ids: accepted}, directives}
    end
  end

  defp validate_incoming_todo_mount(
         {:ok, state, _directives} = accepted,
         %{arguments: %{todo: %Aikido.Todo.Item{}}} = input
       ) do
    path = state.options.todo_path

    case Map.get(input.context.aikido.agent.state, path) do
      %Aikido.Todo.Slice{} -> accepted
      _ -> {:error, :todo_slice_not_mounted}
    end
  end

  defp validate_incoming_todo_mount(result, _input), do: result

  defp resume_waiting_conversation(input) do
    input.arguments.state
    |> record_incoming_message_metadata(input.arguments)
    |> RunState.resume_waiting_run(
      UserMessage.content(input.arguments.text, input.arguments.content_parts)
    )
  end

  defp queue_incoming_conversation_text(input) do
    input.arguments.state
    |> queue_text_for_next_model_request(
      UserMessage.content(input.arguments.text, input.arguments.content_parts)
    )
    |> record_incoming_message_metadata(input.arguments)
    |> then(&{:ok, &1, []})
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
    with {:ok, state, directives} <-
           RunState.begin_run(
             %{
               query: input.arguments.text,
               content_parts: input.arguments.content_parts,
               request_id: input.arguments.request_id,
               metadata: input.arguments.metadata
             },
             input.arguments.state
           ) do
      {:ok, state, directives}
      |> RunCaller.bind_run_caller(input)
      |> HookQueue.queue_event_hooks(:run_started, %{query: input.arguments.text})
    end
  end
end
