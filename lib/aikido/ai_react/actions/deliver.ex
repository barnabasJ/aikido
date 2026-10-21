defmodule Aikido.AiReact.Actions.Deliver do
  @moduledoc "Queues scoped delivery during active work or opens a run with its delivery correlation."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Hooks, Run, Scope}

  @impl true
  def run(input, _opts, _context) do
    with :ok <- Scope.validate(input.arguments.state, input) do
      reduce(input)
    end
  end

  defp reduce(input) do
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
      case Run.open(
             %{
               query: input.arguments.text,
               request_id: input.arguments.request_id,
               metadata: input.arguments.metadata
             },
             input.arguments.state
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
    end
  end
end
