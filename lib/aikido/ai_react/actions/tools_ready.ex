defmodule Aikido.AiReact.Actions.ToolsReady do
  @moduledoc "Installs prepared tools and releases queued work for the matching setup run."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Hooks, Preparation}
  alias Aikido.AiReact.Directives.LLMCall
  alias Aikido.AiReact.Context

  @impl true
  def run(input, _opts, _context) do
    input |> reduce() |> Preparation.finish(input)
  end

  defp reduce(input) do
    state = input.arguments.state

    if state.request_id == input.arguments.request_id && state.status == :setup &&
         Map.get(state, :tool_preparation, []) != [] do
      state =
        Context.append_messages(
          state,
          Enum.map(state.queued_messages, &ReqLLM.Context.user/1)
        )

      state = Map.put(state, :queued_messages, [])

      {directives, state} =
        Enum.map_reduce(state.tool_preparation, state, fn
          %LLMCall{} = effect, state ->
            {state, effect} = Hooks.prepare_model(state, effect)
            {effect, state}

          effect, state ->
            {effect, state}
        end)

      state =
        state
        |> Map.put(:status, :running)
        |> Map.put(:prepared_tools, input.arguments.prepared_tools)
        |> Map.put(:tool_preparation, [])

      Aikido.Types.ActionResult.new(state: state, directives: directives)
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end
end
