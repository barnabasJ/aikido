defmodule Aikido.Ownership.Slice do
  @moduledoc "Logical parent and child bindings, orphan policies and process monitor transitions."
  use Aikido.Slice

  slice do
    name "ownership"

    schema do
      attribute :parent, :term do
        description "Current logical parent reference."
      end

      attribute :orphaned_from, :term do
        description "Former parent retained after surviving its process exit."
      end

      attribute :parent_monitor, :term do
        description "Transient monitor reference for the current parent process."
      end

      attribute :on_parent_death, Aikido.Ownership.Types.ParentDeathPolicy do
        description "Whether to stop or continue when the logical parent dies."
        default :stop
        allow_nil? false
      end

      attribute :children, :map do
        description "Live owned children keyed by their topology tag."
        default %{}
        allow_nil? false
      end
    end

    route Aikido.Ownership.Signals.Configure, Aikido.Ownership.Actions.Configure, public?: false

    route Aikido.Ownership.Signals.AttachParent, Aikido.Ownership.Actions.AttachParent,
      public?: false

    route Aikido.Ownership.Signals.ParentMonitored, Aikido.Ownership.Actions.RecordParentMonitor,
      public?: false

    route Aikido.Ownership.Signals.ParentDied, Aikido.Ownership.Actions.ParentDied, public?: false

    route Aikido.AgentServer.Signals.LifecycleReady, Aikido.Ownership.Actions.AnnounceChild,
      public?: false

    route Aikido.Ownership.Signals.ChildStarted, Aikido.Ownership.Actions.TrackChild,
      public?: false

    route Aikido.Ownership.Signals.ChildMonitored, Aikido.Ownership.Actions.RecordChildMonitor,
      public?: false

    route Aikido.Ownership.Signals.ChildExit, Aikido.Ownership.Actions.ForgetChild, public?: false

    route Aikido.Ownership.Signals.StopChildRequested, Aikido.Ownership.Actions.StopChild,
      public?: false

    route Aikido.AgentServer.Signals.LifecycleStopping, Aikido.Ownership.Actions.ReleaseMonitors,
      public?: false
  end

  @doc false
  def externalize(state),
    do: %{state | children: %{}, parent: nil, orphaned_from: nil, parent_monitor: nil}

  @doc false
  def reinstate(state), do: externalize(state)
end
