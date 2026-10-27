defmodule Aikido.Ownership.Signals.IdentityOrphaned do
  @moduledoc """
  Emitted by the ownership action when a child completes the orphan transition
  under `on_parent_death: :emit_orphan`.

  Queued as `aikido.agent.identity.orphaned` after
  `aikido.agent.identity.parent_died`. The `aikido.agent.orphaned` signal
  (`Aikido.Ownership.Signals.Orphaned`) carries flattened former-parent
  details for action-level routing; this signal is the canonical
  identity-transition marker.

  ## Fields

  - `:former_parent` - The `%Aikido.Ownership.ParentRef{}` that has died.
  - `:reason` - Exit reason from the parent process.
  """

  use Aikido.Signal

  signal do
    type "aikido.agent.identity.orphaned"

    schema do
      attribute :former_parent, :term do
        allow_nil? false
        description "%ParentRef{} of the parent that died"
      end

      attribute :reason, :term do
        allow_nil? false
        description "Exit reason from the parent process"
      end
    end
  end
end
