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

  ## Transition-local outputs (`outputs`) and `staged_outputs`

  A producer action may return `outputs`: a map folded onto the staged context
  for the subsequent actions of the SAME signal. A consumer action on the same
  signal type declares an explicitly LOWER route priority (so it runs after the
  producer) and reads the producer's exact namespaced key from its private
  stage context:

      # Producer (slice route at its default -10 priority)
      Aikido.Types.ActionResult.new(
        changes: %{log: batch},
        outputs: %{accepted_messages: batch}
      )

      # Consumer (agent route on the SAME signal type, explicitly lower
      # priority, e.g. -20)
      producer_key = {{MyApp.SourceSlice, :emit}, :src}

      accepted =
        input.context.aikido[:staged_outputs]
        |> Map.get(producer_key, %{})
        |> Map.get(:accepted_messages, [])

  Contract:

  - **Exact namespace.** Every output is stored under
    `{{producer_resource, producer_action}, mount_path}`. Read that named key;
    never enumerate the whole staged map — map iteration order is not part of
    the contract.
  - **Explicit route priority.** One signal type may match several routes;
    targets run in router precedence order (path class, then declared
    `priority:`, then declaration order). Declare the consumer's priority
    explicitly lower than the producer's.
  - **Same-transition lifetime.** The fold lives in the staged accumulator
    only: it is stripped before state adoption (notifications and checkpoints
    never carry it) and dies at the staged transaction boundary. No residue
    survives into a later signal.
  - **The application owns durable writes.** Outputs are a handoff to the
    application's subsequent actions; nothing is persisted on their behalf.
    Writing the application's Thread (or any other durable record) remains the
    consumer action's own responsibility.
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
      description "Transition-local reducer outputs folded onto the staged context for " <>
                    "subsequent actions of the SAME signal, namespaced by producer action " <>
                    "reference and mount path. Never persisted: the fold lives in the " <>
                    "staged accumulator only, is stripped before state adoption, and dies " <>
                    "with the staged transaction."

      allow_nil? false
      default %{}
    end
  end
end
