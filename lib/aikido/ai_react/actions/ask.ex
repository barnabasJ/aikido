defmodule Aikido.AiReact.Actions.Ask do
  @moduledoc "Starts a configured run, rejecting concurrent setup or model work."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Completion, Run, Scope}

  @impl true
  def run(input, _opts, _context) do
    input
    |> reduce()
    |> Scope.bind(input)
    |> Completion.transition(
      input,
      :run_started,
      Map.take(input.arguments, [:query, :tool_call_id, :name, :content, :reason, :metadata])
    )
  end

  defp reduce(input) do
    data = Map.delete(input.arguments, :state)
    slice = input.arguments.state

    if slice.status in [:setup, :running] do
      {:error, :busy}
    else
      Run.open(data, slice)
    end
  end
end
