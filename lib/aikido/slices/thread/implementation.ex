defmodule Aikido.Slices.Thread.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, [action: :append], _context) do
    %Ash.Union{value: entry} = input.arguments.entry
    slice = input.arguments.state
    thread = append_ensure_thread(slice)

    Aikido.ActionResult.new(
      state: Aikido.Slices.Thread.append(thread, entry),
      directives: []
    )
  end

  @impl true
  def run(input, [action: :clear], _context) do
    slice = input.arguments.state

    case slice do
      %Aikido.Slices.Thread{} = thread ->
        Aikido.ActionResult.new(state: Aikido.Slices.Thread.clear(thread), directives: [])

      _ ->
        Aikido.ActionResult.new(state: Aikido.Slices.Thread.new(), directives: [])
    end
  end

  @impl true
  def run(input, [action: :ensure], _context) do
    data = Map.delete(input.arguments, :state)
    slice = input.arguments.state

    case slice do
      %Aikido.Slices.Thread{} = thread ->
        Aikido.ActionResult.new(state: thread, directives: [])

      _ ->
        Aikido.ActionResult.new(
          state: Aikido.Slices.Thread.new(Map.to_list(data)),
          directives: []
        )
    end
  end

  defp append_ensure_thread(%Aikido.Slices.Thread{} = thread) do
    thread
  end

  defp append_ensure_thread(_) do
    Aikido.Slices.Thread.new()
  end
end
