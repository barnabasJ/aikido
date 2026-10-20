defmodule Aikido.Slices.Todo do
  @moduledoc """
  Optional, durable work list. Mount as `slice :todos, Aikido.Slices.Todo`.

  Callers supply stable item IDs and arbitrary metadata (for example their own
  workflow IDs). Completing an item records explicit evidence; this slice does
  not verify application-specific claims or write application databases.
  `options.completion: :todos` on AiReact holds its final answer until every
  blocking item completes. A blocked or expired item fails that run.

  Change signals are local protocol messages, through direct process delivery.
  Observe changes with `Aikido.AgentServer.subscribe/4`.
  """
  use Ash.Resource,
    data_layer: :embedded,
    extensions: [Aikido.Ash.Slice]

  slice do
    name "todos"

    schema do
      attribute :items, {:array, Aikido.Slices.Todo.Item} do
        description "Durable work items and their explicit completion or blocking evidence."
        public? true
        default []
        allow_nil? false
      end

      attribute :revision, :integer do
        description "Monotonic work-list revision used to identify new item generations."
        public? true
        default 0
        allow_nil? false
      end
    end

    route Aikido.Signals.Todo.TodoAdd, Aikido.Slices.Todo.Implementation
    route Aikido.Signals.Todo.TodoRemove, Aikido.Slices.Todo.Implementation
    route Aikido.Signals.Todo.TodoActivate, Aikido.Slices.Todo.Implementation
    route Aikido.Signals.Todo.TodoComplete, Aikido.Slices.Todo.Implementation
    route Aikido.Signals.Todo.TodoBlock, Aikido.Slices.Todo.Implementation
    route Aikido.Signals.Todo.Expire, Aikido.Slices.Todo.Implementation, public?: false
  end

  @doc false
  def externalize(state), do: state
  @doc false
  def reinstate(state) do
    # Timers are process-local. Do not leave a lost deadline pretending to run.
    items =
      Enum.map(state.items, fn item ->
        if(item.status in [:pending, :active] && Map.get(item, :timeout_ms),
          do: Map.merge(item, %{status: :blocked, reason: :interrupted}),
          else: item
        )
      end)

    %{state | items: items}
  end
end
