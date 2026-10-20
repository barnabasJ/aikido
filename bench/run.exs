{options, selected, invalid} = OptionParser.parse(System.argv(), strict: [quick: :boolean])
suites = %{"actions" => Aikido.Bench.Actions, "context" => Aikido.Bench.Context}

if invalid != [] || Enum.any?(selected, &(!Map.has_key?(suites, &1))) do
  Mix.raise("Usage: mix bench [--quick] [actions|context ...]")
end

settings =
  if options[:quick],
    do: [warmup: 0.1, time: 0.1, memory_time: 0.1, reduction_time: 0.1],
    else: [warmup: 2, time: 5, memory_time: 1, reduction_time: 1]

for suite <- if(selected == [], do: Enum.sort(Map.keys(suites)), else: Enum.uniq(selected)) do
  IO.write("""

  Aikido benchmark: #{suite}
  """)

  Code.require_file(Path.join(__DIR__, "#{suite}.exs"))
  module = Map.fetch!(suites, suite)
  module.run(settings)
end
