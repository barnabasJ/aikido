defmodule Aikido.Types.ActionResult do
  @moduledoc """
  The result of a native Ash agent action: attribute changes and validated I/O directives.

  Actions are pure: return attribute changes and descriptors for all side effects.
  Only directives perform I/O; actions must never execute those effects themselves.

  Construct results with `new/1` or `new!/1`. The execution boundary also validates
  returned maps and structs before applying state or executing any directives.
  `changes` contains optional attribute keys for the action's own mounted path.
  Omitted keys stay unchanged; supplied values are cast by the native update action.
  Supply nested attribute maps for embedded edits, using normal Ash embedded
  update/replacement semantics. Existing embedded structs retain Ash's native
  trusted-value behavior.
  """
  use Ash.TypedStruct

  typed_struct do
    field :changes, :map do
      description "Sparse attribute changes for the action's own mounted path."
    end

    field :directives, {:array, Aikido.Types.Directive} do
      description "Ordered I/O descriptors executed only after the returned state is adopted."
      allow_nil? false
      default []
    end

    field :outputs, :map do
      description(
        "Transition-local reducer outputs folded onto the staged context for " <>
          "subsequent actions of the SAME signal, namespaced by producer action " <>
          "reference and mount path. Never persisted: the fold lives in the " <>
          "staged accumulator only, is stripped before state adoption, and dies " <>
          "with the staged transaction."
      )

      allow_nil? false
      default %{}
    end
  end
end
