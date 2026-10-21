defmodule Aikido.Actions.Noop do
  @moduledoc """
  Pure reducer that returns the supplied `state` unchanged with no directives.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: input.arguments.state, directives: [])
  end
end
