defmodule Aikido.Slices.Thread.Implementation do
  @moduledoc """
  Pure reducers for preserving a thread, appending entries and clearing.

  The native action name selects `:ensure`, `:append` or `:clear`.
  Returns the next thread state without directives, using the input signal for
  timestamps and stable entry identifiers.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(%{action: %{name: :append}} = input, _opts, _context) do
    %Ash.Union{value: entry} = input.arguments.entry
    thread = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Thread.append(thread, entry, entry_options(input, thread)),
      directives: []
    )
  end

  @impl true
  def run(%{action: %{name: :clear}} = input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Thread.clear(input.arguments.state, options(input)),
      directives: []
    )
  end

  @impl true
  def run(%{action: %{name: :ensure}} = input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: input.arguments.state, directives: [])
  end

  defp options(input) do
    [now: Aikido.Signal.timestamp(get_in(input.context, [:aikido, :signal]))]
  end

  defp entry_options(input, thread) do
    Keyword.put(options(input), :id_generator, fn seq -> "#{thread.id}:#{thread.rev}:#{seq}" end)
  end
end
