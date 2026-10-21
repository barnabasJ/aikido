defmodule Aikido.Team.Actions.OperationCompleted do
  @moduledoc "Acknowledges lifecycle completion while preserving the completed team state."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{Inputs}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.read(input)
    Inputs.result(reduce(signal, state, context, config))
  end

  defp reduce(_signal, state, _context, _config), do: {:ok, state, []}
end
