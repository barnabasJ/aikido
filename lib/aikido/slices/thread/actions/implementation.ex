defmodule Aikido.Slices.Thread.Actions.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, [action: :append], _context) do
    entry = input.arguments[:entry]
    slice = input.arguments.state
    thread = append_ensure_thread(slice)

    Aikido.ActionResult.new(
      state: Aikido.Slices.Thread.State.append(thread, entry),
      directives: []
    )
  end

  @impl true
  def run(input, [action: :clear], _context) do
    slice = input.arguments.state

    case slice do
      %Aikido.Slices.Thread.State{} = thread ->
        Aikido.ActionResult.new(state: Aikido.Slices.Thread.State.clear(thread), directives: [])

      _ ->
        Aikido.ActionResult.new(state: Aikido.Slices.Thread.State.new(), directives: [])
    end
  end

  @impl true
  def run(input, [action: :ensure], _context) do
    data = Map.delete(input.arguments, :state)
    slice = input.arguments.state

    case slice do
      %Aikido.Slices.Thread.State{} = thread ->
        Aikido.ActionResult.new(state: thread, directives: [])

      _ ->
        Aikido.ActionResult.new(
          state: Aikido.Slices.Thread.State.new(Map.to_list(data)),
          directives: []
        )
    end
  end

  defp append_ensure_thread(%Aikido.Slices.Thread.State{} = thread) do
    thread
  end

  defp append_ensure_thread(_) do
    Aikido.Slices.Thread.State.new()
  end
end
