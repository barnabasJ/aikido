defmodule Aikido.Slices.Memory.Implementation do
  @moduledoc """
  Pure reducers for named memory spaces and their map or list contents.

  The native action name selects space replacement or a content update.
  Returns the next memory state without directives, deriving timestamps
  deterministically from the input context.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(%{action: %{name: :append_to_space}} = input, _opts, _context) do
    name = input.arguments[:space]
    item = input.arguments[:item]
    memory = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Memory.append_to_space(memory, name, item, options(input)),
      directives: []
    )
  end

  @impl true
  def run(%{action: %{name: :delete_from_space}} = input, _opts, _context) do
    name = input.arguments[:space]
    key = input.arguments[:key]
    memory = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Memory.delete_from_space(memory, name, key, options(input)),
      directives: []
    )
  end

  @impl true
  def run(%{action: %{name: :delete_space}} = input, _opts, _context) do
    name = input.arguments[:space]
    memory = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Memory.delete_space(memory, name, options(input)),
      directives: []
    )
  end

  @impl true
  def run(%{action: %{name: :ensure}} = input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: input.arguments.state, directives: [])
  end

  @impl true
  def run(%{action: %{name: :ensure_space}} = input, _opts, _context) do
    name = input.arguments[:space]

    default =
      case input.arguments.default do
        %Ash.Union{value: value} -> value
        nil -> nil
      end

    memory = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Memory.ensure_space(memory, name, default, options(input)),
      directives: []
    )
  end

  @impl true
  def run(%{action: %{name: :put_in_space}} = input, _opts, _context) do
    name = input.arguments[:space]
    key = input.arguments[:key]
    value = input.arguments[:value]
    memory = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Memory.put_in_space(memory, name, key, value, options(input)),
      directives: []
    )
  end

  @impl true
  def run(%{action: %{name: :put_space}} = input, _opts, _context) do
    name = input.arguments[:space]
    space = input.arguments.value
    memory = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Memory.put_space(memory, name, space, options(input)),
      directives: []
    )
  end

  @impl true
  def run(%{action: %{name: :update_space}} = input, _opts, _context) do
    name = input.arguments[:space]
    new_space = input.arguments.value
    memory = input.arguments.state

    Aikido.Types.ActionResult.new(
      state:
        Aikido.Slices.Memory.update_space(
          memory,
          name,
          fn _existing -> new_space end,
          options(input)
        ),
      directives: []
    )
  end

  defp options(input) do
    [now: Aikido.Signal.timestamp(get_in(input.context, [:aikido, :signal]))]
  end
end
