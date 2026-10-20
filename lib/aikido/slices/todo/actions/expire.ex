defmodule Aikido.Slices.Todo.Actions.Expire do
  @moduledoc "Blocks a current pending or active todo on timeout and ignores obsolete expirations."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Slices.Todo.Items

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    item = Items.find(input)

    if is_nil(item) || item.revision != input.arguments.revision ||
         item.status not in [:pending, :active] do
      Aikido.Types.ActionResult.new(state: state)
    else
      Items.replace(input, %{item | status: :blocked, reason: :timeout})
    end
  end
end
