defmodule Aikido.Bench.Router do
  @moduledoc false

  alias Aikido.Signal.Router
  alias Aikido.Signal.Router.Index

  def run(settings) do
    inputs =
      Map.new([{:exact, 16}, {:exact, 256}, {:mixed, 256}, {:predicate, 64}], fn {kind, size} ->
        {"#{kind}/#{size}: 100 prebuilt signals", routing_input(kind, size)}
      end)

    Benchee.run(benchmark_jobs(), Keyword.put(settings, :inputs, inputs))
  end

  defp routing_input(kind, size) do
    owned = kind |> benchmark_routes(size) |> Router.new!()
    signals = benchmark_signals(size)
    assert_expected_targets(owned, signals, size)
    %{owned: owned, signals: signals}
  end

  defp benchmark_routes(kind, size) do
    routes =
      for index <- 1..size do
        path = "topic.item#{index}.done"

        if kind == :predicate,
          do: {path, fn signal -> signal.data.allowed end, {:handler, index}},
          else: {path, {:handler, index}}
      end

    routes =
      if kind == :mixed,
        do: routes ++ [{"topic.*.done", :single}, {"topic.**", :multi}, {"**", :all}],
        else: routes

    routes
  end

  defp benchmark_signals(size) do
    for index <- 1..100 do
      %Aikido.Signal{
        id: "fixture",
        source: "/bench",
        type: "topic.item#{rem(index, size) + 1}.done",
        data: %{allowed: true}
      }
    end
  end

  defp assert_expected_targets(owned, signals, size) do
    for {signal, index} <- Enum.with_index(signals, 1) do
      {:ok, targets} = Router.route(owned, signal)
      true = targets == Index.lookup(owned, signal.type, signal)
      true = {:handler, rem(index, size) + 1} in targets
    end
  end

  defp benchmark_jobs do
    %{
      "public routing with tagged result" => fn input ->
        Enum.map(input.signals, &Router.route(input.owned, &1))
      end,
      "owned v3 matching core" => fn input ->
        Enum.map(input.signals, &Index.lookup(input.owned, &1.type, &1))
      end
    }
  end
end
