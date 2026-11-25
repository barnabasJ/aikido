defmodule Aikido.AiReact.Actions.ModelAttempt do
  @moduledoc "Adopts bounded model attempt facts for the current run through ordinary slice changes."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, _context) do
    state = input.arguments.state
    observation = input.arguments.observation
    observation = resolve_terminal_attempt(observation, state.model_attempts)
    key = identity(observation)

    if state.request_id == observation.request_id && not is_nil(Map.get(observation, :attempt)) do
      history = state.model_attempts
      previous = Enum.find(history, &(identity(&1) == key)) || %{}
      updated = Map.merge(previous, observation)
      history = [updated | Enum.reject(history, &(identity(&1) == key))] |> Enum.take(32)
      Aikido.Types.ActionResult.new(changes: %{model_attempts: history})
    else
      Aikido.Types.ActionResult.new(changes: %{})
    end
  end

  defp identity(record),
    do: {record.mode, Map.get(record, :handoff_id), record.iteration, Map.get(record, :attempt)}

  defp resolve_terminal_attempt(%{phase: :terminal} = observation, history) do
    case Enum.find(history, fn record ->
           record.mode == observation.mode && record.iteration == observation.iteration &&
             Map.get(record, :handoff_id) == Map.get(observation, :handoff_id)
         end) do
      nil -> observation
      record -> Map.put(observation, :attempt, record.attempt)
    end
  end

  defp resolve_terminal_attempt(observation, _history), do: observation
end
