defmodule Aikido.Jido.Examples.Counter do
  @moduledoc "A Jido-owned counter exposing its named input through Ash."
  use Jido.Agent, name: "ash_counter"
  use Aikido.Jido

  state do
    schema(Zoi.object(%{count: Zoi.integer() |> Zoi.default(0)}))
  end

  routes do
    signal_source("/examples/ash-counter")

    route "counter.add", as: :add do
      action %{amount: amount},
        schema: Zoi.object(%{amount: Zoi.integer() |> Zoi.min(1) |> Zoi.default(1)}),
        context: context do
        {:ok, %{count: context.agent_state.count + amount}}
      end
    end
  end
end
