defmodule Aikido.Slices.Memory.Actions.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, [action: :append_to_space], _context) do
    name = input.arguments[:space]
    item = input.arguments[:item]
    slice = input.arguments.state
    memory = append_to_space_ensure_memory(slice)

    Aikido.ActionResult.new(
      state: Aikido.Slices.Memory.State.append_to_space(memory, name, item),
      directives: []
    )
  end

  @impl true
  def run(input, [action: :delete_from_space], _context) do
    name = input.arguments[:space]
    key = input.arguments[:key]
    slice = input.arguments.state
    memory = delete_from_space_ensure_memory(slice)

    Aikido.ActionResult.new(
      state: Aikido.Slices.Memory.State.delete_from_space(memory, name, key),
      directives: []
    )
  end

  @impl true
  def run(input, [action: :delete_space], _context) do
    name = input.arguments[:space]
    slice = input.arguments.state
    memory = delete_space_ensure_memory(slice)

    Aikido.ActionResult.new(
      state: Aikido.Slices.Memory.State.delete_space(memory, name),
      directives: []
    )
  end

  @impl true
  def run(input, [action: :ensure], _context) do
    data = Map.delete(input.arguments, :state)
    slice = input.arguments.state

    case slice do
      %Aikido.Slices.Memory.State{} = memory ->
        Aikido.ActionResult.new(state: memory, directives: [])

      _ ->
        Aikido.ActionResult.new(
          state: Aikido.Slices.Memory.State.new(Map.to_list(data)),
          directives: []
        )
    end
  end

  @impl true
  def run(input, [action: :ensure_space], _context) do
    name = input.arguments[:space]
    default = input.arguments[:default]
    slice = input.arguments.state
    memory = ensure_space_ensure_memory(slice)

    Aikido.ActionResult.new(
      state: Aikido.Slices.Memory.State.ensure_space(memory, name, default),
      directives: []
    )
  end

  @impl true
  def run(input, [action: :put_in_space], _context) do
    name = input.arguments[:space]
    key = input.arguments[:key]
    value = input.arguments[:value]
    slice = input.arguments.state
    memory = put_in_space_ensure_memory(slice)

    Aikido.ActionResult.new(
      state: Aikido.Slices.Memory.State.put_in_space(memory, name, key, value),
      directives: []
    )
  end

  @impl true
  def run(input, [action: :put_space], _context) do
    name = input.arguments[:space]
    (%Aikido.Slices.Memory.Space{} = space) = input.arguments[:value]
    slice = input.arguments.state
    memory = put_space_ensure_memory(slice)

    Aikido.ActionResult.new(
      state: Aikido.Slices.Memory.State.put_space(memory, name, space),
      directives: []
    )
  end

  @impl true
  def run(input, [action: :update_space], _context) do
    name = input.arguments[:space]
    (%Aikido.Slices.Memory.Space{} = new_space) = input.arguments[:value]
    slice = input.arguments.state
    memory = update_space_ensure_memory(slice)

    Aikido.ActionResult.new(
      state: Aikido.Slices.Memory.State.update_space(memory, name, fn _existing -> new_space end),
      directives: []
    )
  end

  defp append_to_space_ensure_memory(%Aikido.Slices.Memory.State{} = memory) do
    memory
  end

  defp append_to_space_ensure_memory(_) do
    Aikido.Slices.Memory.State.new()
  end

  defp delete_from_space_ensure_memory(%Aikido.Slices.Memory.State{} = memory) do
    memory
  end

  defp delete_from_space_ensure_memory(_) do
    Aikido.Slices.Memory.State.new()
  end

  defp delete_space_ensure_memory(%Aikido.Slices.Memory.State{} = memory) do
    memory
  end

  defp delete_space_ensure_memory(_) do
    Aikido.Slices.Memory.State.new()
  end

  defp ensure_space_ensure_memory(%Aikido.Slices.Memory.State{} = memory) do
    memory
  end

  defp ensure_space_ensure_memory(_) do
    Aikido.Slices.Memory.State.new()
  end

  defp put_in_space_ensure_memory(%Aikido.Slices.Memory.State{} = memory) do
    memory
  end

  defp put_in_space_ensure_memory(_) do
    Aikido.Slices.Memory.State.new()
  end

  defp put_space_ensure_memory(%Aikido.Slices.Memory.State{} = memory) do
    memory
  end

  defp put_space_ensure_memory(_) do
    Aikido.Slices.Memory.State.new()
  end

  defp update_space_ensure_memory(%Aikido.Slices.Memory.State{} = memory) do
    memory
  end

  defp update_space_ensure_memory(_) do
    Aikido.Slices.Memory.State.new()
  end
end
