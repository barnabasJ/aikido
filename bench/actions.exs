defmodule Aikido.Bench.Actions do
  @moduledoc false

  def run(settings) do
    inputs = benchmark_inputs()
    jobs = benchmark_jobs()
    assert_equivalent_results(inputs, jobs)
    Benchee.run(jobs, Keyword.put(settings, :inputs, inputs))
  end

  defp benchmark_inputs do
    Map.new([1, 100, 10_000], fn size ->
      entries = Map.new(1..size, &{"key_#{&1}", &1})

      memory =
        Ash.create!(Aikido.Memory.Slice, %{
          id: "benchmark-memory",
          spaces: %{
            world: Aikido.Memory.Types.Space.new!(data: entries),
            tasks: Aikido.Memory.Types.Space.new!(data: [])
          }
        })

      params = %{state: memory, space: :world, key: "benchmark", value: 1}
      input = Ash.ActionInput.for_action(Aikido.Memory.Slice, :put_in_space, params)
      {"#{size} memory keys", %{params: params, input: input}}
    end)
  end

  defp benchmark_jobs() do
    %{
      "cast input + run Ash reducer" => fn data ->
        input = Ash.ActionInput.for_action(Aikido.Memory.Slice, :put_in_space, data.params)
        {:ok, result} = Ash.run_action(input)
        result
      end,
      "run Ash reducer (prepared input)" => fn data ->
        {:ok, result} = Ash.run_action(data.input)
        result
      end
    }
  end

  defp assert_equivalent_results(inputs, jobs) do
    # Check that both scenarios perform the same update before timing them.
    for {_label, input} <- inputs do
      results = Enum.map(jobs, fn {_name, job} -> job.(input) end)
      [result | _] = results
      true = Enum.all?(results, &(&1 == result))
      1 = result.state.spaces.world.data["benchmark"]
      [] = result.directives
    end
  end
end
