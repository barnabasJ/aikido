defmodule Aikido.Types.ActionResult do
  @moduledoc """
  The result of a native Ash agent action: its next state and validated I/O directives.

  Actions are pure: return the next state and descriptors for all side effects.
  Only directives perform I/O; actions must never execute those effects themselves.

  Construct results with `new/1` or `new!/1`. The execution boundary also validates
  returned maps and structs before applying state or executing any directives.
  State may be a slice map, a typed state struct, or a multi-slice update.
  """
  use Ash.TypedStruct

  typed_struct do
    field :state, :term do
      description "Next value for the action's state path, or an explicit multi-slice update."
    end

    field :directives, {:array, Aikido.Types.Directive} do
      description "Ordered I/O descriptors executed only after the returned state is adopted."
      allow_nil? false
      default []
    end
  end
end
