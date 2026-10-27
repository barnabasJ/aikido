defmodule Aikido.Ownership.Signals.ChildExit do
  @moduledoc false

  use Aikido.Signal

  signal do
    type "aikido.agent.child.exit"

    schema do
      attribute :child_id, :string do
        description "Stable logical identity of the exited child when known."
      end

      attribute :monitor_ref, :term do
        description "Monitor reference that observed this exit; absent for an explicit notification."
      end

      attribute :tag, :term do
        allow_nil? false
        description "Tag assigned to the child when spawned"
      end

      attribute :pid, :term do
        allow_nil? false
        description "PID of the child process that exited"
      end

      attribute :reason, :term do
        allow_nil? false
        description "Exit reason from the child process"
      end
    end
  end
end
