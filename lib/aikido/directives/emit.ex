defmodule Aikido.Directives.Emit do
  @moduledoc """
  Deliver one signal directly to a process as `{:signal, signal}`.

  Omitting `target` sends to the current agent. Delivery is asynchronous and
  preserves sender ordering, including a reply followed by agent shutdown.
  Use `Aikido.Directives.Notify` for native Ash notifications.
  """
  use Aikido.Directive

  typed_struct do
    field :signal, :term do
      description "Signal descriptor materialized and delivered with the originating caller scope."
      allow_nil? false
    end

    field :target, :term do
      description "Destination PID; defaults to the current agent"
    end
  end

  @impl true
  def exec(%{signal: signal, target: target}, input_signal, _runtime) do
    signal =
      signal
      |> Aikido.Directive.materialize_signal()
      |> Aikido.Signal.inherit(input_signal)

    send(target || self(), {:signal, signal})
    :ok
  end
end
