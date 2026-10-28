defmodule Aikido.AiReact.Actions.RefreshTools do
  @moduledoc "Merges tool configuration and schedules one correlated preparation at a safe boundary."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    with {:ok, state, directives} <- request_tool_refresh(input) do
      changes =
        if state == input.arguments.state,
          do: %{},
          else: Map.take(state, Enum.map(Ash.Resource.Info.attributes(input.resource), & &1.name))

      Aikido.Types.ActionResult.new(changes: changes, directives: directives)
    end
  end

  defp request_tool_refresh(input) do
    with :ok <- Aikido.AiReact.RunCaller.validate_run_caller(input.arguments.state, input) do
      state = update_tool_configuration(input.arguments.state, input.arguments)

      cond do
        state.status == :setup && map_size(state.hooks_pending) == 0 ->
          Aikido.AiReact.RunState.request_tool_setup(state)

        state.status in [:setup, :running] ->
          {:ok, %{state | tool_refresh_pending: true}, []}

        true ->
          {:ok, state, []}
      end
    end
  end

  defp update_tool_configuration(state, arguments) do
    replacements =
      arguments
      |> Map.take([:tools, :tool_options])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    state
    |> Map.merge(replacements)
    |> Map.update!(:tool_context, &DeepMerge.deep_merge(&1, arguments.tool_context))
  end
end
