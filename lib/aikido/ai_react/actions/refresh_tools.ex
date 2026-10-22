defmodule Aikido.AiReact.Actions.RefreshTools do
  @moduledoc "Merges tool configuration and schedules one correlated preparation at a safe boundary."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    with :ok <- Aikido.AiReact.RunCaller.validate_run_caller(input.arguments.state, input) do
      state = update_tool_configuration(input.arguments.state, input.arguments)

      cond do
        state.status == :setup && map_size(state.hooks_pending) == 0 ->
          Aikido.AiReact.RunState.request_tool_setup(state)

        state.status in [:setup, :running] ->
          Aikido.Types.ActionResult.new(state: %{state | tool_refresh_pending: true})

        true ->
          Aikido.Types.ActionResult.new(state: state)
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
