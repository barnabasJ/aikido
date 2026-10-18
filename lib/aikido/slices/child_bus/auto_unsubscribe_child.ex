defmodule Aikido.Slices.ChildBus.AutoUnsubscribeChild do
  @moduledoc """
  Action invoked by `Aikido.Slices.ChildBus` on every `aikido.agent.child.exit`
  signal the host agent receives (emitted by
  `AgentServer.handle_child_down/3` when a monitored child process
  dies).

  Looks up the subscription ids previously stored by
  `Aikido.Slices.ChildBus.RecordSubscription` for this tag, removes the
  entry from the slice, and emits one
  unsubscribe-child directive per
  sub_id. The directive performs the actual `Jido.Signal.Bus.unsubscribe/2`
  I/O. This action itself is pure — its only outputs are its return
  value (slice with the tag removed + directive list).
  """
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  @persist {:aikido_action_metadata,
            %{
              name: "child_bus_auto_unsubscribe_child",
              description: "Drop a child's subscription tracking and emit unsubscribe directives."
            }}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term
      argument :tag, :term, allow_nil?: false
      argument :pid, :term, allow_nil?: true
      argument :reason, :term, allow_nil?: true
      description "Drop a child's subscription tracking and emit unsubscribe directives."
      run Aikido.Slices.ChildBus.AutoUnsubscribeChild.Implementation
    end
  end
end
