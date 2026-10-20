defmodule Aikido.Slices.AiReact.Actions.Handoff do
  @moduledoc "Replaces conversation context only while the run is inactive."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Slices.AiReact.Preparation
  alias Aikido.Slices.AiReact.Context

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
