Mix.ensure_application!(:tools)

defmodule AgentExamples.Bench.InspectorCost do
  def run do
    :rand.seed(:exsss, {42, 43, 44})
    numbers = Enum.shuffle(Enum.to_list(1..1024))

    scenarios = [
      {"no inspector", nil, false},
      {"root state only", &AgentExamples.Playground.snapshot/2, false},
      {"tree signal identities", fn runtime, event -> {:ok, {runtime.id, event.signal.type}} end,
       true},
      {"tree full state", &AgentExamples.Playground.snapshot/2, true}
    ]

    cond do
      "--profile" in System.argv() ->
        profile_capture(numbers)

      "--benchee" in System.argv() ->
        inputs =
          Map.new(scenarios, fn {label, projection, children?} ->
            {label, {numbers, projection, children?}}
          end)

        Benchee.run(%{"sort" => &sort/1},
          inputs: inputs,
          before_each: &start_root/1,
          after_each: &stop_root/1,
          time: 5,
          warmup: 0,
          memory_time: 0,
          reduction_time: 0,
          parallel: 1
        )

      true ->
        for round <- 1..3,
            {label, projection, children?} <-
              Enum.drop(scenarios, rem(round - 1, 4)) ++ Enum.take(scenarios, rem(round - 1, 4)) do
          run = start_root({numbers, projection, children?})
          started = System.monotonic_time(:microsecond)

          try do
            sort(run)
            elapsed = (System.monotonic_time(:microsecond) - started) / 1000
            IO.puts(Jason.encode!(%{round: round, scenario: label, sort_ms: elapsed}))
          after
            stop_root(run)
          end
        end
    end
  end

  defp profile_capture(numbers) do
    run = start_root({numbers, &AgentExamples.Playground.snapshot/2, true})

    modules = [
      Aikido.Inspector,
      Aikido.Inspector.History,
      Aikido.Inspector.History.Redaction,
      Aikido.Inspector.History.Bounds,
      Aikido.Inspector.History.ActionTelemetry
    ]

    Enum.each(modules, &Code.ensure_loaded!/1)

    try do
      :tprof.profile(fn -> sort(run) end, %{
        type: :call_time,
        rootset: :all,
        pattern: Enum.map(modules, &{&1, :_, :_}),
        report: {:total, {:measurement, :descending}}
      })
    after
      stop_root(run)
    end
  end

  defp start_root({numbers, projection, children?}) do
    root = AgentExamples.Agents.quicksort_start!(%{})

    ref =
      if projection,
        do: elem(Aikido.Inspector.attach(root, projection, include_children?: children?), 1)

    %{root: root, ref: ref, numbers: numbers}
  end

  defp sort(run) do
    signal =
      AgentExamples.Quicksort.Signals.Sort.new!(%{
        numbers: run.numbers,
        topic: "inspector-cost-probe"
      })

    {:ok, sorted} =
      Aikido.AgentServer.call_until(
        run.root.pid,
        signal,
        "**",
        fn runtime ->
          state = runtime.agent.state.state

          case state.status do
            :completed -> {:ok, state.result}
            :failed -> {:error, state.error}
            _ -> :skip
          end
        end,
        timeout: 120_000
      )

    true = sorted == Enum.to_list(1..1024)
    run
  end

  defp stop_root(run) do
    if run.ref, do: Aikido.Inspector.detach(run.ref)
    AgentExamples.Agents.quicksort_stop!(run.root)
    drain()
  end

  defp drain do
    receive do
      {:aikido_inspection, _, _} -> drain()
    after
      0 -> :ok
    end
  end
end

store = System.fetch_env!("AIKIDO_DURABLE_DIR")
if File.exists?(store), do: raise("Choose a new, isolated AIKIDO_DURABLE_DIR")
{:ok, _} = Application.ensure_all_started(:agent_examples)
Logger.configure(level: :warning)
AgentExamples.Bench.InspectorCost.run()
