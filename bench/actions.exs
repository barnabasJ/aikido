defmodule Aikido.Bench.Actions do
  @moduledoc false

  alias Aikido.Slices.Memory

  def run(settings) do
    inputs =
      Map.new([1, 100, 10_000], fn size ->
        entries = Map.new(1..size, &{"key_#{&1}", &1})
        memory = Memory.new(id: "benchmark-memory", now: 0)
        memory = Memory.put_space(memory, :world, Memory.Space.new!(data: entries), now: 0)
        params = %{state: memory, space: :world, key: "benchmark", value: 1}
        input = Ash.ActionInput.for_action(Memory, :put_in_space, params)
        {"#{size} memory keys", %{params: params, input: input}}
      end)

    jobs = %{
      "cast input + run Ash reducer" => fn data ->
        input = Ash.ActionInput.for_action(Memory, :put_in_space, data.params)
        {:ok, result} = Ash.run_action(input)
        result
      end,
      "run Ash reducer (prepared input)" => fn data ->
        {:ok, result} = Ash.run_action(data.input)
        result
      end
    }

    # Check that both scenarios perform the same update before timing them.
    for {_label, input} <- inputs do
      results = Enum.map(jobs, fn {_name, job} -> job.(input) end)
      [result | _] = results
      true = Enum.all?(results, &(&1 == result))
      1 = Memory.get_in_space(result.state, :world, "benchmark")
      [] = result.directives
    end

    Benchee.run(jobs, Keyword.put(settings, :inputs, inputs))
  end
end
