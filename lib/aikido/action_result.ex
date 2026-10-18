defmodule Aikido.ActionResult do
  @moduledoc """
  The result of a native Ash agent action: its next state and validated I/O directives.

  Construct results with `new/1` or `new!/1`. The execution boundary also validates
  returned maps and structs before applying state or executing any directives.
  State may be a slice map, a typed state struct, or a multi-slice update.
  """
  use Ash.TypedStruct

  typed_struct do
    field :state, :term
    field :directives, {:array, Aikido.Types.Directive}, allow_nil?: false, default: []
  end
end
