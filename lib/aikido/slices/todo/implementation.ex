defmodule Aikido.Slices.Todo.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  def run(input, [action: :remove], _context) do
    state = input.arguments.state
    id = input.arguments.id

    if Enum.any?(state.items, &(&1.id == id)) do
      Aikido.ActionResult.new(
        state: %{
          state
          | items: Enum.reject(state.items, &(&1.id == id)),
            revision: state.revision + 1
        },
        directives: [
          Aikido.Directives.emit(
            Jido.Signal.new!("aikido.todo.changed", %{id: id, removed: true})
          )
        ]
      )
    else
      {:error, "Unknown todo ID"}
    end
  end

  def run(input, [action: action], _context) do
    state = input.arguments.state
    data = input.arguments
    item = Enum.find(state.items, &(&1.id == data.id))

    cond do
      action == :add && item ->
        {:error, "Todo ID already exists"}

      action != :add && is_nil(item) ->
        {:error, "Unknown todo ID"}

      action == :expire &&
          (item.revision != data.revision || item.status not in [:pending, :active]) ->
        Aikido.ActionResult.new(state: state)

      action != :add && item.status == :completed ->
        Aikido.ActionResult.new(state: state)

      true ->
        revision = state.revision + 1

        next =
          case action do
            :add ->
              %{
                id: data.id,
                text: data.text,
                metadata: data.metadata,
                blocking?: data.blocking?,
                status: :pending,
                result: nil,
                reason: nil,
                revision: revision,
                timeout_ms: data[:timeout_ms]
              }

            :activate ->
              %{item | status: :active}

            :complete ->
              %{item | status: :completed, result: data[:result], reason: nil}

            :block ->
              %{item | status: :blocked, reason: data.reason}

            :expire ->
              %{item | status: :blocked, reason: :timeout}
          end

        next =
          if is_struct(next),
            do: next,
            else:
              Aikido.Slices.Todo.Item.new!(Map.reject(next, fn {_, value} -> is_nil(value) end))

        items =
          if action == :add,
            do: state.items ++ [next],
            else:
              Enum.map(state.items, fn item -> if item.id == data.id, do: next, else: item end)

        state = %{state | items: items, revision: revision}
        changed = Jido.Signal.new!("aikido.todo.changed", %{id: data.id, item: next})
        effects = [Aikido.Directives.emit(changed)]

        effects =
          if action == :add && data[:timeout_ms] do
            effects ++
              [
                Aikido.Directives.schedule(
                  data.timeout_ms,
                  Jido.Signal.new!("aikido.todo.expire", %{id: data.id, revision: revision})
                )
              ]
          else
            effects
          end

        Aikido.ActionResult.new(state: state, directives: effects)
    end
  end
end
