defmodule Aikido.AiReact.Completion do
  @moduledoc "Pure todo completion requirements and terminal run resource release."

  @doc "Resolve completion requirements and release terminal resources in an action result."
  def apply_completion_requirements({:ok, %{state: state, directives: []}} = unchanged, input)
      when state == input.arguments.state,
      do: unchanged

  def apply_completion_requirements(
        {:ok, %{state: %{status: :completed} = state} = result},
        input
      ) do
    agent_state = (input.context.aikido[:agent] && input.context.aikido.agent.state) || %{}

    state =
      state
      |> resolve_todo_status(agent_state)
      |> release_terminal_resources()

    {:ok, %{result | state: state}}
  end

  def apply_completion_requirements({:ok, %{state: %{status: :failed} = state} = result}, _input) do
    {:ok, %{result | state: release_terminal_resources(state)}}
  end

  def apply_completion_requirements(result, _input), do: result

  @doc "Resolve completed, waiting or failed status from the configured blocking todos."
  def resolve_todo_status(state, agent_state) do
    options = Map.get(state, :options) || %Aikido.AiReact.Options{}

    if options.completion == :todos do
      case Map.get(agent_state, options.todo_path) do
        %{items: items} -> resolve_blocking_todos(state, Enum.filter(items, & &1.blocking?))
        _ -> Map.merge(state, %{status: :failed, error: :todo_slice_not_mounted})
      end
    else
      state
    end
  end

  @doc "Discard prepared tools and pending handoff only after a run completes or fails."
  def release_terminal_resources(%{status: status} = state) when status in [:completed, :failed],
    do: Aikido.AiReact.Run.clear_tools_and_handoff(state)

  def release_terminal_resources(state), do: state

  defp resolve_blocking_todos(state, items) do
    cond do
      blocked = Enum.find(items, &(&1.status == :blocked)) ->
        Map.merge(state, %{
          status: :failed,
          error: {:todo_blocked, blocked.id, blocked.reason}
        })

      Enum.any?(items, &(&1.status != :completed)) ->
        Map.put(state, :status, :waiting)

      true ->
        Map.put(state, :status, :completed)
    end
  end
end
