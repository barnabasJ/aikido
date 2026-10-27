defmodule Aikido.Todo.Types.Status do
  @moduledoc "Lifecycle states of a tracked todo item."
  use Ash.Type.Enum,
    values: [
      pending: "The item has not started.",
      active: "Work on the item is active.",
      completed: "The item has explicit completion evidence.",
      blocked: "The item cannot proceed, expired or was interrupted."
    ]
end
