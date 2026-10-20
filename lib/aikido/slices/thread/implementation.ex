defmodule Aikido.Slices.Thread.Implementation do
  @moduledoc """
  Pure reducers for thread initialization, entry append and clearing.

  The configured `:action` option selects `:ensure`, `:append` or `:clear`.
  Returns the next thread state without directives, using the input signal for
  timestamps and stable thread/entry identifiers.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, [action: :append], _context) do
    %Ash.Union{value: entry} = input.arguments.entry
    slice = input.arguments.state
    thread = append_ensure_thread(slice, input)

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Thread.append(thread, entry, entry_options(input, thread)),
      directives: []
    )
  end

  @impl true
  def run(input, [action: :clear], _context) do
    slice = input.arguments.state

    case slice do
      %Aikido.Slices.Thread{} = thread ->
        Aikido.Types.ActionResult.new(
          state: Aikido.Slices.Thread.clear(thread, options(input)),
          directives: []
        )

      _ ->
        Aikido.Types.ActionResult.new(
          state: Aikido.Slices.Thread.new(initial_options(input)),
          directives: []
        )
    end
  end

  @impl true
  def run(input, [action: :ensure], _context) do
    data = Map.delete(input.arguments, :state)
    slice = input.arguments.state

    case slice do
      %Aikido.Slices.Thread{} = thread ->
        Aikido.Types.ActionResult.new(state: thread, directives: [])

      _ ->
        Aikido.Types.ActionResult.new(
          state:
            Aikido.Slices.Thread.new(
              Keyword.merge(
                initial_options(input),
                Enum.reject(Map.to_list(data), fn {_, value} -> is_nil(value) end)
              )
            ),
          directives: []
        )
    end
  end

  defp append_ensure_thread(%Aikido.Slices.Thread{} = thread, _input) do
    thread
  end

  defp append_ensure_thread(_, input) do
    Aikido.Slices.Thread.new(initial_options(input))
  end

  defp options(input) do
    [now: Aikido.SignalCtx.timestamp(get_in(input.context, [:aikido, :signal]))]
  end

  defp initial_options(input) do
    runtime = input.context[:aikido] || %{}
    signal = runtime[:signal]
    seed = {signal && signal.id, runtime[:agent_id], runtime[:slice_path], input.arguments}
    id = :crypto.hash(:sha256, :erlang.term_to_binary(seed)) |> Base.url_encode64(padding: false)
    Keyword.put(options(input), :id, "thread_" <> id)
  end

  defp entry_options(input, thread) do
    Keyword.put(options(input), :id_generator, fn seq -> "#{thread.id}:#{thread.rev}:#{seq}" end)
  end
end
