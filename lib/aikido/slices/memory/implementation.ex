defmodule Aikido.Slices.Memory.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, [action: :append_to_space], _context) do
    name = input.arguments[:space]
    item = input.arguments[:item]
    slice = input.arguments.state
    memory = ensure_memory(slice, input)

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Memory.append_to_space(memory, name, item, options(input)),
      directives: []
    )
  end

  @impl true
  def run(input, [action: :delete_from_space], _context) do
    name = input.arguments[:space]
    key = input.arguments[:key]
    slice = input.arguments.state
    memory = ensure_memory(slice, input)

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Memory.delete_from_space(memory, name, key, options(input)),
      directives: []
    )
  end

  @impl true
  def run(input, [action: :delete_space], _context) do
    name = input.arguments[:space]
    slice = input.arguments.state
    memory = ensure_memory(slice, input)

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Memory.delete_space(memory, name, options(input)),
      directives: []
    )
  end

  @impl true
  def run(input, [action: :ensure], _context) do
    data = Map.delete(input.arguments, :state)
    slice = input.arguments.state

    case slice do
      %Aikido.Slices.Memory{} = memory ->
        Aikido.Types.ActionResult.new(state: memory, directives: [])

      _ ->
        Aikido.Types.ActionResult.new(
          state:
            Aikido.Slices.Memory.new(
              Keyword.merge(
                options(input),
                Enum.reject(Map.to_list(data), fn {_, value} -> is_nil(value) end)
              )
            ),
          directives: []
        )
    end
  end

  @impl true
  def run(input, [action: :ensure_space], _context) do
    name = input.arguments[:space]

    default =
      case input.arguments.default do
        %Ash.Union{value: value} -> value
        nil -> nil
      end

    slice = input.arguments.state
    memory = ensure_memory(slice, input)

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Memory.ensure_space(memory, name, default, options(input)),
      directives: []
    )
  end

  @impl true
  def run(input, [action: :put_in_space], _context) do
    name = input.arguments[:space]
    key = input.arguments[:key]
    value = input.arguments[:value]
    slice = input.arguments.state
    memory = ensure_memory(slice, input)

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Memory.put_in_space(memory, name, key, value, options(input)),
      directives: []
    )
  end

  @impl true
  def run(input, [action: :put_space], _context) do
    name = input.arguments[:space]
    (%Aikido.Slices.Memory.Space{} = space) = input.arguments[:value]
    slice = input.arguments.state
    memory = ensure_memory(slice, input)

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Memory.put_space(memory, name, space, options(input)),
      directives: []
    )
  end

  @impl true
  def run(input, [action: :update_space], _context) do
    name = input.arguments[:space]
    (%Aikido.Slices.Memory.Space{} = new_space) = input.arguments[:value]
    slice = input.arguments.state
    memory = ensure_memory(slice, input)

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

  defp ensure_memory(%Aikido.Slices.Memory{} = memory, _input), do: memory
  defp ensure_memory(_, input), do: Aikido.Slices.Memory.new(options(input))

  defp options(input) do
    runtime = input.context[:aikido] || %{}
    signal = runtime[:signal]
    seed = {signal && signal.id, runtime[:agent_id], runtime[:slice_path], input.arguments}
    id = :crypto.hash(:sha256, :erlang.term_to_binary(seed)) |> Base.url_encode64(padding: false)
    [now: Aikido.SignalCtx.timestamp(signal), id: "mem_" <> id]
  end
end
