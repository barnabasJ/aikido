defmodule Aikido.Todo.Slice do
  @moduledoc """
  Optional, durable work list. Mount as `slice :todos, Aikido.Todo.Slice`.

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
    extensions: [Aikido.Slice.Extension]

  slice do
    name "todos"

    schema do
      attribute :items, {:array, Aikido.Todo.Item} do
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

    route Aikido.AiReact.Signals.Deliver, Aikido.Todo.Actions.AcceptDelivery,
      public?: false,
      name: :accept_delivery

    route Aikido.Todo.Signals.TodoAdd, Aikido.Todo.Actions.Add
    route Aikido.Todo.Signals.TodoRemove, Aikido.Todo.Actions.Remove
    route Aikido.Todo.Signals.TodoActivate, Aikido.Todo.Actions.Activate
    route Aikido.Todo.Signals.TodoComplete, Aikido.Todo.Actions.Complete
    route Aikido.Todo.Signals.TodoBlock, Aikido.Todo.Actions.Block
    route Aikido.Todo.Signals.Expire, Aikido.Todo.Actions.Expire, public?: false
  end

  @doc false
  def externalize(state), do: state
  @doc false
  def reinstate(state, %{fresh?: true}), do: state

  def reinstate(state, %{fresh?: false}), do: reinstate(state)

  @doc false
  def reinstate(state) do
    # Timers are process-local. Do not leave a lost deadline pretending to run.
    items =
      Enum.map(Map.get(state, :items, []), fn item ->
        if(item.status in [:pending, :active] && Map.get(item, :timeout_ms),
          do: Map.merge(item, %{status: :blocked, reason: :interrupted}),
          else: item
        )
      end)

    Map.put(state, :items, items)
  end
end
