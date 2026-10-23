defmodule Aikido.Directives.Emit do
  @moduledoc """
  Deliver one signal directly to a process as `{:signal, signal}`.

  Omitting `target` sends to the current agent. Delivery is asynchronous and
  preserves sender ordering, including a reply followed by agent shutdown.
  Use `Aikido.Directives.Notify` for native Ash notifications.
  """
  use Aikido.Directive

  typed_struct do
    field :signal, Aikido.Signal do
      description "Signal descriptor materialized and delivered with the originating caller scope."
      allow_nil? false
    end

    field :inherit_scope?, :boolean do
      description "Fill missing scope and tracing from the triggering signal; disable when replaying an already scoped command."
      default true
      allow_nil? false
    end

    field :target, :term do
      description "Destination PID; defaults to the current agent"
    end
  end

  @impl true
  def exec(%{signal: signal, target: target} = directive, input_signal, _runtime) do
    signal = Aikido.Directive.materialize_signal(signal)

    signal =
      if Map.get(directive, :inherit_scope?, true),
        do: Aikido.Signal.inherit(signal, input_signal),
        else: signal

    send(target || self(), {:signal, signal})
    :ok
  end
end
