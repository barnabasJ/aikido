defmodule AgentExamples.AdaptiveAssistant.Commands.PrepareModel do
  @moduledoc "Applies one transient generation default through the native model request contract."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _options, _context) do
    Aikido.AiReact.Types.ModelRequest.new(
      model: input.arguments.model,
      options: Keyword.put_new(input.arguments.options, :max_tokens, 4096)
    )
  end
end
