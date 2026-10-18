defmodule AgentExamples.Actions.Add do
  use Aikido.Action

  action do
    name "add"

    schema do
      attribute :amount, :integer, allow_nil?: false
    end
  end

  @impl true
  def run(signal, state, _opts, _context) do
    {:ok, %{state | count: state.count + signal.data.amount}, []}
  end
end
