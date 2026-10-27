defmodule Aikido.Ownership.Types.ParentDeathPolicy do
  @moduledoc "How an agent reacts when its parent process exits."
  use Ash.Type.Enum,
    values: [
      stop: "Stop the child with its parent.",
      continue: "Continue without a parent.",
      emit_orphan: "Continue and emit an orphan notification."
    ]
end
