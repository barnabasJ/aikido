defmodule AgentExamples.Quicksort.Bench.RuntimeProfile do
  @moduledoc "Native BEAM measurements for the scale benchmark; no event payloads are retained."

  def start do
    :msacc.reset()
    :msacc.start()
  end

  def finish(output) do
    :msacc.stop()
    stats = :msacc.stats()
    File.write!(output <> ".msacc.json", Jason.encode!(stats))
    :msacc.to_file(String.to_charlist(output <> ".msacc.terms"))
    stats
  end

  def wall_time do
    case :erlang.statistics(:scheduler_wall_time) do
      rows when is_list(rows) ->
        Map.new(rows, fn {id, active, total} -> {id, {active, total}} end)

      _ ->
        %{}
    end
  end

  def utilization(previous, current) do
    for {id, {active, total}} <- current,
        {before_active, before_total} = Map.get(previous, id, {active, total}),
        total > before_total do
      %{scheduler: id, utilization: (active - before_active) / (total - before_total)}
    end
  end
end
