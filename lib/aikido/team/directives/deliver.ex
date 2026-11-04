defmodule Aikido.Team.Directives.Deliver do
  @moduledoc "Delivers one correlated team signal without transferring execution authority."
  use Aikido.Directive

  typed_struct do
    field :signal, Aikido.Signal do
      description "Task or result signal to deliver after the sender's state is adopted."
      allow_nil? false
    end

    field :target, :term do
      description "Recipient PID already resolved by the owning team."
      allow_nil? false
    end

    field :kind, Aikido.Team.Types.DeliveryKind do
      description "Native task, completion, result or cancellation boundary."
      allow_nil? false
    end

    field :signal_type, :string do
      description "Signal type selected by the originating team action."
      allow_nil? false
    end

    field :recipient, Aikido.Agent.Reference do
      description "Exact durable address selected by a member lifecycle operation."
    end

    field :member, :term do
      description "Topology name selected by a member lifecycle operation."
    end

    field :operation_id, :string do
      description "Tracked member stop operation, absent for late-activation cleanup."
    end

    field :request_id, :string do
      description "Receiving conversation request that owned the assignment."
    end

    field :active?, :boolean do
      description "Whether the assignment belonged to an active receiving run."
      default false
      allow_nil? false
    end
  end

  @impl true
  def exec(delivery, input, runtime) do
    signal =
      delivery.signal |> Aikido.Directive.materialize_signal() |> Aikido.Signal.inherit(input)

    Aikido.Signal.Delivery.send(
      Aikido.Team.Delivery,
      delivery.target,
      signal,
      runtime,
      Map.take(delivery, [
        :kind,
        :signal_type,
        :request_id,
        :active?,
        :recipient,
        :target,
        :member,
        :operation_id
      ])
    )

    :ok
  end
end
