defmodule Aikido.AiReact.Actions.Deliver do
  @moduledoc """
  Adds incoming text to this AI agent's conversation, such as a worker's task result.

  While the agent is setting up or working, queues the text for its next model
  request and records the incoming message's request ID and metadata. Otherwise,
  starts a new run with that text, request ID and metadata. Incoming messages
  must respect the active run's actor and tenant.
  """
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Hooks, Run, Scope}

  @impl true
  def run(input, _opts, _context) do
    with :ok <- Scope.validate(input.arguments.state, input) do
      queue_delivery_or_start_run(input)
    end
  end

  defp queue_delivery_or_start_run(input) do
    if input.arguments.state.status in [:setup, :running] do
      state =
        input.arguments.state
        |> Map.update(:queued_messages, [input.arguments.text], &(&1 ++ [input.arguments.text]))
        |> Map.update(:run_metadata, %{}, fn metadata ->
          delivery = Map.take(input.arguments, [:request_id, :metadata])
          Map.update(metadata, :deliveries, [delivery], &(&1 ++ [delivery]))
        end)

      Aikido.Types.ActionResult.new(state: state)
    else
      with {:ok, result} <-
             Run.open(
               %{
                 query: input.arguments.text,
                 request_id: input.arguments.request_id,
                 metadata: input.arguments.metadata
               },
               input.arguments.state
             ) do
        {:ok, result}
        |> Scope.bind(input)
        |> Hooks.queue_event_hooks(:run_started, %{query: input.arguments.text})
      end
    end
  end
end
