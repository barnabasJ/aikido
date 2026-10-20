defmodule Aikido.AgentServer.Signal.IdentityOrphaned do
  @moduledoc """
  Emitted by the AgentServer when a child completes the orphan transition
  under `on_parent_death: :emit_orphan`.

  Delivered as `aikido.agent.identity.orphaned` immediately after
  `aikido.agent.identity.parent_died`. The `aikido.agent.orphaned` signal
  (`Aikido.AgentServer.Signal.Orphaned`) carries flattened former-parent
  details for action-level routing; this signal is the canonical
  identity-transition marker.

  ## Fields

  - `:former_parent` - The `%Aikido.AgentServer.ParentRef{}` that has died.
  - `:reason` - Exit reason from the parent process.
  """

  use Jido.Signal,
    type: "aikido.agent.identity.orphaned",
    extension_policy: [{Jido.Signal.Ext.Dispatch, :optional}],
    schema: [
      former_parent: [
        type: :any,
        required: true,
        doc: "%ParentRef{} of the parent that died"
      ],
      reason: [type: :any, required: true, doc: "Exit reason from the parent process"]
    ]
end
