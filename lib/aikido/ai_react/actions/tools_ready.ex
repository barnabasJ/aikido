defmodule Aikido.AiReact.Actions.ToolsReady do
  @moduledoc "Installs prepared tools and starts the matching run's first model request."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.Hooks
  alias Aikido.AiReact.Directives.LLMCall

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state

    if state.request_id == input.arguments.request_id && state.status == :setup &&
         is_nil(state.prepared_tools) do
      {tools, _registry} = input.arguments.prepared_tools

      state =
        state
        |> Map.put(:status, :running)
        |> Map.put(:prepared_tools, input.arguments.prepared_tools)

      directive = %LLMCall{
        options: state.options,
        iteration: 1,
        client: state.client,
        model: state.model,
        context: state.context,
        request_id: state.request_id,
        llm_opts: state.llm_opts,
        tools: tools
      }

      Hooks.before_model(state, directive)
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end
end
