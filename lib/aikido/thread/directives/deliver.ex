defmodule Aikido.Thread.Directives.Deliver do
  @moduledoc "Deliver one journal protocol signal to a running durable address without activating it."
  use Aikido.Directive

  typed_struct do
    field :target, Aikido.Agent.Reference do
      description "Durable destination, resolved afresh for each delivery."
      allow_nil? false
    end

    field :signal, Aikido.Signal do
      description "One typed Follow, Ack, Batch or Gap protocol message."
      allow_nil? false
    end

    field :kind, Aikido.Thread.Types.DeliveryKind do
      description "Request retains consumer authority; batch uses recipient authority."
      allow_nil? false
    end
  end

  @impl true
  def exec(directive, input, runtime) do
    if directive.signal.type == "aikido.thread.batch" do
      send(self(), {:aikido_journal_sync, directive, input})
      :ok
    else
      Aikido.Thread.Delivery.send(
        directive.target,
        directive.signal,
        directive.kind,
        input,
        runtime
      )
    end
  end
end
