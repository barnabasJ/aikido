defmodule Aikido.AgentServer.Signals.ParentDied do
  @moduledoc """
  Emitted by the AgentServer when the agent's logical parent process dies.

  Delivered as `aikido.agent.identity.parent_died` from the parent-`:DOWN`
  handler. Independent of the `on_parent_death` policy: `:continue` and
  `:emit_orphan` agents see this signal as the identity transition;
  the `aikido.agent.orphaned` signal — only on `:emit_orphan` — carries
  former-parent details alongside.

  ## Fields

  - `:former_parent` - The `%Aikido.AgentServer.ParentRef{}` that has died.
  - `:reason` - Exit reason from the parent process.
  """

  use Aikido.Signal

  signal do
    type "aikido.agent.identity.parent_died"

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
