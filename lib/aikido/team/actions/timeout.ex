defmodule Aikido.Team.Actions.Timeout do
  @moduledoc "Fails a correlated lifecycle operation when its completion deadline expires."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{Inputs, Operation}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, _config} = Inputs.read(input)

    %{operation_id: signal.data.operation_id, reason: :timeout}
    |> Operation.failed(state, context)
    |> Inputs.result()
  end
end
