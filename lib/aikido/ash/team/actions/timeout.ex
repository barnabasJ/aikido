defmodule Aikido.Ash.Team.Actions.Timeout do
  @moduledoc "Fails a correlated lifecycle operation when its completion deadline expires."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Ash.Team.{Inputs, Operation}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.read(input)
    Inputs.result(reduce(signal, state, context, config))
  end

  defp reduce(signal, state, context, _config),
    do:
      Operation.failed(
        %{operation_id: signal.data.operation_id, reason: :timeout},
        state,
        context
      )
end
