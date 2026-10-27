defmodule Aikido.Cron.Actions.AcknowledgeJobEvent do
  @moduledoc """
  Accepts shutdown and restart acknowledgements without changing current ownership.

  Ownership is adopted by Registered or removed by CancelRequested. A delayed
  acknowledgement can therefore never remove a replacement scheduler.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context), do: Aikido.Types.ActionResult.new(state: input.arguments.state)
end
