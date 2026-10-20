defmodule Aikido.Ash.Team.Actions.ChildStarted do
  @moduledoc "Acknowledges child startup while the correlated activation result owns member adoption."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Ash.Team.{Inputs}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.read(input)
    Inputs.result(reduce(signal, state, context, config))
  end

  defp reduce(_signal, state, _context, _config), do: {:ok, state, []}
end
