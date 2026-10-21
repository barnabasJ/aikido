defmodule Aikido.AiReact.Completion do
  @moduledoc "Pure todo completion gating and lifecycle hook transitions."

  @doc false
  def transition(result, input, event, payload) do
    result =
      case result do
        {:ok, %{state: %{status: :completed} = state} = result} ->
          {:ok,
           %{
             result
             | state:
                 gate(
                   state,
                   (input.context.aikido[:agent] && input.context.aikido.agent.state) || %{}
                 )
           }}

        other ->
          other
      end

    case result do
      {:ok, %{state: state}} when state != input.arguments.state ->
        Aikido.AiReact.Hooks.transition(result, event, payload)

      _ ->
        result
    end
  end

  @doc false
  def gate(state, agent_state) do
    options = Map.get(state, :options) || %Aikido.AiReact.Options{}

    if options.completion == :todos do
      case Map.get(agent_state, options.todo_path) do
        %{items: items} ->
          blocking = Enum.filter(items, & &1.blocking?)

          cond do
            blocked = Enum.find(blocking, &(&1.status == :blocked)) ->
              Map.merge(state, %{
                status: :failed,
                error: {:todo_blocked, blocked.id, blocked.reason}
              })

            Enum.any?(blocking, &(&1.status != :completed)) ->
              Map.put(state, :status, :waiting)

            true ->
              Map.put(state, :status, :completed)
          end

        _ ->
          Map.merge(state, %{status: :failed, error: :todo_slice_not_mounted})
      end
    else
      state
    end
  end
end
