defmodule Aikido.AiReact.Actions.ReplaceContext do
  @moduledoc "Installs caller-supplied conversation history while idle and refreshes the cached token estimate."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.Conversation

  @impl true
  def run(input, _opts, _context) do
    with {:ok, state, directives} <- replace_idle_conversation(input) do
      changes =
        if state == input.arguments.state,
          do: %{},
          else:
            Map.take(state, [:context, :estimated_tokens, :last_input_tokens, :last_input_shape])

      Aikido.Types.ActionResult.new(changes: changes, directives: directives)
    end
  end

  defp replace_idle_conversation(input) do
    state = input.arguments.state

    if state.status in [:setup, :running, :waiting] do
      {:error, :busy}
    else
      with {:ok, context} <- ReqLLM.Context.normalize(input.arguments.messages) do
        {:ok, Conversation.replace_context(state, context), []}
      end
    end
  end
end
