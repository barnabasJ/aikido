defmodule Aikido.Slices.ChildBus do
  @moduledoc """
  Wires an agent's children to a `Jido.Signal.Bus` automatically.

  When a child agent boots under a parent that declared this slice, the
  child emits `aikido.agent.child.started` back to the parent during its
  post-init hook. This slice routes that signal to an action that
  subscribes the child's pid to every path declared by the child
  agent's `signal_routes/0`, against the bus named in the slice's
  config.

  The slice does not start the bus — the caller is responsible for
  starting `Jido.Signal.Bus` (or wiring one up via a Aikido instance).
  The slice assumes the bus already exists and is addressable by the
  configured atom at subscription time.

  ## Usage

      defmodule MyApp.Fulfillment do
        use Aikido.Agent

        agent do
          name "fulfillment"
        end

        slices do
          slice :child_bus, Aikido.Slices.ChildBus, options: [bus: :my_bus]
        end
      end

  ## Routes

  Bare slices register their `signal_routes/0` with **absolute** paths;
  slice-declared routes do not get a per-instance prefix (see
  `Aikido.Slice.Instance`). The two inbound routes
  (`aikido.agent.child.started`, `aikido.agent.child.exit`) are
  framework-emitted child lifecycle signals; the two cascade routes
  (`child_bus.subscribed`, `child_bus.subscribe_failed`) are
  self-emitted by the subscribe-child directive
  when the underlying `Jido.Signal.Bus.subscribe/3` returns. The
  cascade actions then settle the result onto slice state. Actions return
  state and directives; directives perform I/O and cast result signals,
  and the receiving actions apply the resulting slice changes.
  """
  use Ash.Resource,
    data_layer: :embedded,
    validate_domain_inclusion?: false,
    extensions: [Aikido.Ash.Slice]

  slice do
    name "child_bus"
    description "Auto-subscribes an agent's children to a named signal bus."

    schema do
      attribute :bus, :atom,
        public?: true,
        allow_nil?: false,
        description: "Name of the Jido.Signal.Bus to subscribe children on."

      attribute :subscriptions, :map,
        public?: true,
        allow_nil?: false,
        default: %{},
        description: "Per-tag subscription-id lists, used for cleanup on child.exit."

      attribute :failed_subscriptions, :map,
        public?: true,
        allow_nil?: false,
        default: %{},
        description: "Per-tag list of subscription failures (path/reason/at) surfaced by the bus."
    end

    route "aikido.agent.child.started", :auto_subscribe_child
    route "aikido.agent.child.exit", :auto_unsubscribe_child
    route "child_bus.subscribed", :record_subscription
    route "child_bus.subscribe_failed", :record_subscription_failure
  end

  actions do
    action :auto_subscribe_child, Aikido.ActionResult do
      public? false
      argument :state, :term
      argument :pid, :term, allow_nil?: false
      argument :child_module, :atom, allow_nil?: false
      argument :tag, :term, allow_nil?: false
      argument :parent_id, :string, allow_nil?: true
      argument :child_id, :string, allow_nil?: true
      argument :child_partition, :term, allow_nil?: true
      argument :meta, :map, allow_nil?: true
      description "Emit subscribe directives for each of a child's signal_routes."
      run Aikido.Slices.ChildBus.AutoSubscribeChild
    end

    action :auto_unsubscribe_child, Aikido.ActionResult do
      public? false
      argument :state, :term
      argument :tag, :term, allow_nil?: false
      argument :pid, :term, allow_nil?: true
      argument :reason, :term, allow_nil?: true
      description "Drop a child's subscription tracking and emit unsubscribe directives."
      run Aikido.Slices.ChildBus.AutoUnsubscribeChild
    end

    action :record_subscription, Aikido.ActionResult do
      public? false
      argument :state, :term
      argument :tag, :term, allow_nil?: false
      argument :sub_id, :term, allow_nil?: false
      argument :path, :string, allow_nil?: true
      description "Record a successful child-bus subscription's sub_id."
      run Aikido.Slices.ChildBus.RecordSubscription
    end

    action :record_subscription_failure, Aikido.ActionResult do
      public? false
      argument :state, :term
      argument :tag, :term, allow_nil?: false
      argument :path, :string, allow_nil?: false
      argument :reason, :term, allow_nil?: false
      argument :child_module, :atom, allow_nil?: true
      description "Record a child-bus subscription that failed at the bus."
      run Aikido.Slices.ChildBus.RecordSubscriptionFailure
    end
  end
end
