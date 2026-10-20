defmodule Aikido.Ash.Team.Actions.Failed do
  @moduledoc "Fails the current correlated lifecycle operation and notifies pending task callers."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Ash.Team.{Inputs, Operation}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.read(input)
    Inputs.result(reduce(signal, state, context, config))
  end

  defp reduce(signal, state, context, _config),
    do: Operation.failed(signal.data, state, context)
end
