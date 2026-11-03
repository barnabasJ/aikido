defmodule Aikido.Ownership.Directives.AnnounceChild do
  @moduledoc "Announces one child binding through the correlated internal delivery boundary."
  use Aikido.Directive

  typed_struct do
    field :parent, Aikido.Ownership.ParentRef do
      description "Parent activation which owns this child's attachment."
      allow_nil? false
    end

    field :signal, Aikido.Signal do
      description "Typed child announcement populated by the ownership action."
      allow_nil? false
    end
  end

  @impl true
  def exec(directive, input, runtime) do
    signal =
      directive.signal
      |> Aikido.Directive.materialize_signal()
      |> Aikido.Signal.inherit(input)

    Aikido.Signal.Delivery.send(
      Aikido.Ownership.Delivery,
      directive.parent.pid,
      signal,
      runtime,
      %{}
    )
  end
end
