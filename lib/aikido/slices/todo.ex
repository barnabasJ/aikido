defmodule Aikido.Slices.Todo do
  @moduledoc """
  Optional, durable work list. Mount as `slice :todos, Aikido.Slices.Todo`.

  Callers supply stable item IDs and arbitrary metadata (for example their own
  workflow IDs). Completing an item records explicit evidence; this slice does
  not verify application-specific claims or write application databases.
  `options.completion: :todos` on AiReact holds its final answer until every
  blocking item completes. A blocked or expired item fails that run.
  """
  use Ash.Resource,
    data_layer: :embedded,
    validate_domain_inclusion?: false,
    extensions: [Aikido.Ash.Slice]

  slice do
    name "todos"

    schema do
      attribute :items, {:array, Aikido.Slices.Todo.Item},
        public?: true,
        default: [],
        allow_nil?: false

      attribute :revision, :integer, public?: true, default: 0, allow_nil?: false
    end

    route "aikido.todo.add", :todo_add
    route "aikido.todo.remove", :todo_remove
    route "aikido.todo.activate", :todo_activate
    route "aikido.todo.complete", :todo_complete
    route "aikido.todo.block", :todo_block
    route "aikido.todo.expire", :expire
  end

  actions do
    action :todo_add, Aikido.ActionResult do
      argument :state, :term
      argument :id, :string, allow_nil?: false
      argument :text, :string, allow_nil?: false
      argument :metadata, :map, default: %{}
      argument :blocking?, :boolean, default: true
      argument :timeout_ms, :integer, constraints: [min: 1]
      run {Aikido.Slices.Todo.Implementation, action: :add}
    end

    action :todo_remove, Aikido.ActionResult do
      argument :state, :term
      argument :id, :string, allow_nil?: false
      run {Aikido.Slices.Todo.Implementation, action: :remove}
    end

    action :todo_activate, Aikido.ActionResult do
      argument :state, :term
      argument :id, :string, allow_nil?: false
      run {Aikido.Slices.Todo.Implementation, action: :activate}
    end

    action :todo_complete, Aikido.ActionResult do
      argument :state, :term
      argument :id, :string, allow_nil?: false
      argument :result, :term
      run {Aikido.Slices.Todo.Implementation, action: :complete}
    end

    action :todo_block, Aikido.ActionResult do
      argument :state, :term
      argument :id, :string, allow_nil?: false
      argument :reason, :term, allow_nil?: false
      run {Aikido.Slices.Todo.Implementation, action: :block}
    end

    action :expire, Aikido.ActionResult do
      public? false
      argument :state, :term
      argument :id, :string, allow_nil?: false
      argument :revision, :integer, allow_nil?: false
      run {Aikido.Slices.Todo.Implementation, action: :expire}
    end
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
