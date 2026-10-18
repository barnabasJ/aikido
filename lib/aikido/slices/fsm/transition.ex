defmodule Aikido.Slices.FSM.Transition do
  @moduledoc "Transitions the FSM slice to a new state.\n\nTriggered by a `aikido.fsm.transition` signal with `data: %{to: \"<next>\"}`.\nValidates the requested transition against `slice.transitions`, appends\na `%{from:, to:}` entry to `slice.history`, and flips `terminal?` if the\nnew state is in `slice.terminal_states`.\n"
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
  @persist {:aikido_action_metadata, %{name: "fsm_transition"}}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term
      argument :to, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true]

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end
  end

  defp reduce(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    to = fetch_to(data)
    from = Map.fetch!(slice, :state)
    transitions = Map.get(slice, :transitions, %{})
    allowed = Map.get(transitions, from, [])

    if to in allowed do
      terminal_states = Map.get(slice, :terminal_states, [])
      history = Map.get(slice, :history, []) ++ [%{from: from, to: to}]
      new_slice = %{slice | state: to, history: history, terminal?: to in terminal_states}
      {:ok, new_slice, []}
    else
      {:error, "invalid FSM transition from #{inspect(from)} to #{inspect(to)}"}
    end
  end

  defp fetch_to(%{to: to}) when is_binary(to) do
    to
  end

  defp fetch_to(%{"to" => to}) when is_binary(to) do
    to
  end

  defp fetch_to(other) do
    raise ArgumentError, "missing :to in #{inspect(other)}"
  end
end
