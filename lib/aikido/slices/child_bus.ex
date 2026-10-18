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
  cascade actions then settle the result onto slice state per
  ADR 0019: the action returns directives only, the directive does
  the I/O and casts a result signal, the cascade action mutates the
  slice.
  """

  alias Aikido.Slices.ChildBus.AutoSubscribeChild
  alias Aikido.Slices.ChildBus.AutoUnsubscribeChild
  alias Aikido.Slices.ChildBus.RecordSubscription
  alias Aikido.Slices.ChildBus.RecordSubscriptionFailure

  use Aikido.Slice

  slice do
    name "child_bus"
    description "Auto-subscribes an agent's children to a named signal bus."

    schema do
      attribute :bus, Aikido.Types.Validated,
        allow_nil?: false,
        constraints: [
          type: :atom,
          constraints: [],
          validation: {__MODULE__, :validate_bus_atom, []}
        ],
        description: "Name of the Jido.Signal.Bus to subscribe children on."

      attribute :subscriptions, :map,
        allow_nil?: false,
        default: %{},
        description: "Per-tag subscription-id lists, used for cleanup on child.exit."

      attribute :failed_subscriptions, :map,
        allow_nil?: false,
        default: %{},
        description: "Per-tag list of subscription failures (path/reason/at) surfaced by the bus."
    end
  end

  signal_routes do
    route "aikido.agent.child.started", AutoSubscribeChild
    route "aikido.agent.child.exit", AutoUnsubscribeChild
    route "child_bus.subscribed", RecordSubscription
    route "child_bus.subscribe_failed", RecordSubscriptionFailure
  end

  capabilities do
    capability :bus_wiring
  end

  @doc false
  @spec validate_bus_atom(atom(), keyword()) :: :ok | {:error, String.t()}
  def validate_bus_atom(nil, _opts) do
    {:error, "Aikido.Slices.ChildBus requires a `:bus` atom; got nil"}
  end

  def validate_bus_atom(value, _opts) when is_atom(value) do
    :ok
  end

  def validate_bus_atom(other, _opts) do
    {:error, "Aikido.Slices.ChildBus requires a `:bus` atom; got #{inspect(other)}"}
  end
end
