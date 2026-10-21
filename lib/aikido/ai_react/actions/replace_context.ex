defmodule Aikido.AiReact.Actions.ReplaceContext do
  @moduledoc "Installs caller-supplied conversation history while idle and refreshes the cached token estimate."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.Preparation
  alias Aikido.AiReact.Context

  @impl true
  def run(input, _opts, _context) do
    input |> reduce() |> Preparation.finish(input)
  end

  defp reduce(input) do
    state = input.arguments.state

    if state.status in [:setup, :running, :waiting] do
      {:error, :busy}
    else
      with {:ok, context} <- ReqLLM.Context.normalize(input.arguments.messages) do
        Aikido.Types.ActionResult.new(state: Context.replace_context(state, context))
      end
    end
  end
end
