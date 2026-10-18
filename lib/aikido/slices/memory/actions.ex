defmodule Aikido.Slices.Memory.Actions do
  @moduledoc "Native Ash state-transition actions for the memory slice."
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :append_to_space, Aikido.ActionResult do
      argument :state, :term
      argument :space, :atom, description: "List space name.", allow_nil?: false
      argument :item, :term, description: "Item to append.", allow_nil?: false
      description "Append an item to a list space."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case append_to_space_reduce(
               signal,
               input.arguments.state,
               runtime[:action_opts] || %{},
               runtime
             ) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end

    action :delete_from_space, Aikido.ActionResult do
      argument :state, :term
      argument :space, :atom, description: "Map space name.", allow_nil?: false
      argument :key, :term, description: "Key to remove.", allow_nil?: false
      description "Delete a key from a map space."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case delete_from_space_reduce(
               signal,
               input.arguments.state,
               runtime[:action_opts] || %{},
               runtime
             ) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end

    action :delete_space, Aikido.ActionResult do
      argument :state, :term
      argument :space, :atom, description: "Space name to delete.", allow_nil?: false
      description "Delete a non-reserved space."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case delete_space_reduce(
               signal,
               input.arguments.state,
               runtime[:action_opts] || %{},
               runtime
             ) do
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
      argument :metadata, :map, description: "Optional metadata for new memory.", default: %{}
      argument :id, :string, description: "Optional explicit memory id."
      description "Initialize memory state if missing."

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

    action :ensure_space, Aikido.ActionResult do
      argument :state, :term
      argument :space, :atom, description: "Space name to ensure.", allow_nil?: false

      argument :default, Aikido.Types.Union,
        description: "Default data for the new space (map → kv, list → list).",
        default: %{},
        constraints: [
          types: [[type: :map, constraints: []], [type: {:array, :term}, constraints: []]]
        ]

      description "Create a space with default data if missing."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case ensure_space_reduce(
               signal,
               input.arguments.state,
               runtime[:action_opts] || %{},
               runtime
             ) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end

    action :put_in_space, Aikido.ActionResult do
      argument :state, :term
      argument :space, :atom, description: "Map space name.", allow_nil?: false
      argument :key, :term, description: "Key to set.", allow_nil?: false
      argument :value, :term, description: "Value to associate with `key`.", allow_nil?: false
      description "Set a key in a map space."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case put_in_space_reduce(
               signal,
               input.arguments.state,
               runtime[:action_opts] || %{},
               runtime
             ) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end

    action :put_space, Aikido.ActionResult do
      argument :state, :term
      argument :space, :atom, description: "Space name to set.", allow_nil?: false

      argument :value, :term,
        description: "%Aikido.Slices.Memory.Space{} to install at the named key.",
        allow_nil?: false

      description "Store a space wholesale at the named key."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case put_space_reduce(
               signal,
               input.arguments.state,
               runtime[:action_opts] || %{},
               runtime
             ) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end

    action :update_space, Aikido.ActionResult do
      argument :state, :term
      argument :space, :atom, description: "Space name to update.", allow_nil?: false

      argument :value, :term,
        description: "Replacement %Aikido.Slices.Memory.Space{} value.",
        allow_nil?: false

      description "Replace the value of an existing space."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case update_space_reduce(
               signal,
               input.arguments.state,
               runtime[:action_opts] || %{},
               runtime
             ) do
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

  defp append_to_space_reduce(%Jido.Signal{data: %{space: name, item: item}}, slice, _opts, _ctx) do
    memory = append_to_space_ensure_memory(slice)
    {:ok, Aikido.Slices.Memory.State.append_to_space(memory, name, item), []}
  end

  defp append_to_space_ensure_memory(%Aikido.Slices.Memory.State{} = memory) do
    memory
  end

  defp append_to_space_ensure_memory(_) do
    Aikido.Slices.Memory.State.new()
  end

  defp delete_from_space_reduce(%Jido.Signal{data: %{space: name, key: key}}, slice, _opts, _ctx) do
    memory = delete_from_space_ensure_memory(slice)
    {:ok, Aikido.Slices.Memory.State.delete_from_space(memory, name, key), []}
  end

  defp delete_from_space_ensure_memory(%Aikido.Slices.Memory.State{} = memory) do
    memory
  end

  defp delete_from_space_ensure_memory(_) do
    Aikido.Slices.Memory.State.new()
  end

  defp delete_space_reduce(%Jido.Signal{data: %{space: name}}, slice, _opts, _ctx) do
    memory = delete_space_ensure_memory(slice)
    {:ok, Aikido.Slices.Memory.State.delete_space(memory, name), []}
  end

  defp delete_space_ensure_memory(%Aikido.Slices.Memory.State{} = memory) do
    memory
  end

  defp delete_space_ensure_memory(_) do
    Aikido.Slices.Memory.State.new()
  end

  defp ensure_reduce(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    case slice do
      %Aikido.Slices.Memory.State{} = memory -> {:ok, memory, []}
      _ -> {:ok, Aikido.Slices.Memory.State.new(Map.to_list(data)), []}
    end
  end

  defp ensure_space_reduce(
         %Jido.Signal{data: %{space: name, default: default}},
         slice,
         _opts,
         _ctx
       ) do
    memory = ensure_space_ensure_memory(slice)
    {:ok, Aikido.Slices.Memory.State.ensure_space(memory, name, default), []}
  end

  defp ensure_space_ensure_memory(%Aikido.Slices.Memory.State{} = memory) do
    memory
  end

  defp ensure_space_ensure_memory(_) do
    Aikido.Slices.Memory.State.new()
  end

  defp put_in_space_reduce(
         %Jido.Signal{data: %{space: name, key: key, value: value}},
         slice,
         _opts,
         _ctx
       ) do
    memory = put_in_space_ensure_memory(slice)
    {:ok, Aikido.Slices.Memory.State.put_in_space(memory, name, key, value), []}
  end

  defp put_in_space_ensure_memory(%Aikido.Slices.Memory.State{} = memory) do
    memory
  end

  defp put_in_space_ensure_memory(_) do
    Aikido.Slices.Memory.State.new()
  end

  defp put_space_reduce(
         %Jido.Signal{data: %{space: name, value: %Aikido.Slices.Memory.Space{} = space}},
         slice,
         _opts,
         _ctx
       ) do
    memory = put_space_ensure_memory(slice)
    {:ok, Aikido.Slices.Memory.State.put_space(memory, name, space), []}
  end

  defp put_space_ensure_memory(%Aikido.Slices.Memory.State{} = memory) do
    memory
  end

  defp put_space_ensure_memory(_) do
    Aikido.Slices.Memory.State.new()
  end

  defp update_space_reduce(
         %Jido.Signal{data: %{space: name, value: %Aikido.Slices.Memory.Space{} = new_space}},
         slice,
         _opts,
         _ctx
       ) do
    memory = update_space_ensure_memory(slice)

    {:ok, Aikido.Slices.Memory.State.update_space(memory, name, fn _existing -> new_space end),
     []}
  end

  defp update_space_ensure_memory(%Aikido.Slices.Memory.State{} = memory) do
    memory
  end

  defp update_space_ensure_memory(_) do
    Aikido.Slices.Memory.State.new()
  end
end
