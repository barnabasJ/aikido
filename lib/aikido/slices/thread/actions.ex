defmodule Aikido.Slices.Thread.Actions do
  @moduledoc "Native Ash state-transition actions for the thread slice."
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :append, Aikido.ActionResult do
      argument :state, :term

      argument :entry, Aikido.Types.Union,
        description: "Entry map (or list of entry maps) to append.",
        allow_nil?: false,
        constraints: [
          types: [[type: :map, constraints: []], [type: {:array, :map}, constraints: []]]
        ]

      description "Append one or more entries to the thread."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case append_reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end

    action :clear, Aikido.ActionResult do
      argument :state, :term
      description "Reset the thread to an empty state."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case clear_reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end

    action :ensure, Aikido.ActionResult do
      argument :state, :term

      argument :metadata, :map,
        description: "Optional metadata for newly created thread.",
        default: %{}

      argument :id, :string, description: "Optional explicit thread id."
      description "Initialize thread state if missing."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case ensure_reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
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

  defp append_reduce(%Jido.Signal{data: %{entry: entry}}, slice, _opts, _ctx) do
    thread = append_ensure_thread(slice)
    {:ok, Aikido.Slices.Thread.State.append(thread, entry), []}
  end

  defp append_ensure_thread(%Aikido.Slices.Thread.State{} = thread) do
    thread
  end

  defp append_ensure_thread(_) do
    Aikido.Slices.Thread.State.new()
  end

  defp clear_reduce(%Jido.Signal{}, slice, _opts, _ctx) do
    case slice do
      %Aikido.Slices.Thread.State{} = thread ->
        {:ok, Aikido.Slices.Thread.State.clear(thread), []}

      _ ->
        {:ok, Aikido.Slices.Thread.State.new(), []}
    end
  end

  defp ensure_reduce(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    case slice do
      %Aikido.Slices.Thread.State{} = thread -> {:ok, thread, []}
      _ -> {:ok, Aikido.Slices.Thread.State.new(Map.to_list(data)), []}
    end
  end
end
