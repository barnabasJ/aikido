defmodule Aikido.Slices.Todo.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  def run(input, [action: :remove], _context) do
    state = input.arguments.state
    id = input.arguments.id

    if Enum.any?(state.items, &(&1.id == id)) do
      Aikido.Types.ActionResult.new(
        state: %{
          state
          | items: Enum.reject(state.items, &(&1.id == id)),
            revision: state.revision + 1
        },
        directives: [
          Aikido.Directives.emit_to_pid(
            struct!(Jido.Signal,
              id: nil,
              type: "aikido.todo.changed",
              data: %{id: id, removed: true},
              source: "/aikido"
            ),
            input.context.aikido.agent_pid
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
        Aikido.Types.ActionResult.new(state: state)

      action != :add && item.status == :completed ->
        Aikido.Types.ActionResult.new(state: state)

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

        changed =
          struct!(Jido.Signal,
            id: nil,
            type: "aikido.todo.changed",
            data: %{id: data.id, item: next},
            source: "/aikido"
          )

        effects = [Aikido.Directives.emit_to_pid(changed, input.context.aikido.agent_pid)]

        effects =
          if action == :add && data[:timeout_ms] do
            effects ++
              [
                Aikido.Directives.schedule(
                  data.timeout_ms,
                  struct!(Jido.Signal,
                    id: nil,
                    type: "aikido.todo.expire",
                    data: %{id: data.id, revision: revision},
                    source: "/aikido"
                  )
                )
              ]
          else
            effects
          end

        Aikido.Types.ActionResult.new(state: state, directives: effects)
    end
  end
end
