defmodule AgentExamples.Telemetry do
  @moduledoc """
  LiveDashboard metrics from native Aikido, Ash, ReqLLM and BEAM events.

  Tags describe resources and operations, never prompts, credentials, actors or
  per-run IDs. Charts observe events while open; they do not query agent state.
  Signal timings cover reducers and middleware; directive timings cover dispatch,
  while ReqLLM and Ash action timings include the asynchronous work they execute.
  """
  import Telemetry.Metrics

  def metrics do
    aikido_metrics() ++ agent_metrics() ++ model_metrics() ++ ash_metrics() ++ vm_metrics()
  end

  defp aikido_metrics do
    Enum.map(Aikido.Telemetry.metrics(), fn metric ->
      group = if :signal in metric.event_name, do: "Signals", else: "Directives"
      %{metric | reporter_options: [nav: group]}
    end) ++
      [
        counter("aikido.agent_server.signal.rejected.count",
          measurement: fn _ -> 1 end,
          event_name: [:aikido, :agent_server, :signal, :stop],
          keep: &Map.has_key?(&1, :error),
          tags: [:signal_type],
          description: "Signals rejected by the reducer pipeline",
          reporter_options: [nav: "Signals"]
        ),
        counter("aikido.agent_server.signal.exception.count",
          measurement: fn _ -> 1 end,
          tags: [:agent_module],
          description: "Raised signal-processing failures",
          reporter_options: [nav: "Signals"]
        ),
        summary("aikido.agent_server.directive.stop.duration",
          tags: [:directive_type],
          unit: {:native, :millisecond},
          description: "Directive dispatch duration, excluding asynchronous work",
          reporter_options: [nav: "Directives"]
        ),
        counter("aikido.agent_server.directive.exception.count",
          measurement: fn _ -> 1 end,
          tags: [:directive_type],
          description: "Raised directive-dispatch failures",
          reporter_options: [nav: "Directives"]
        )
      ]
  end

  defp agent_metrics do
    [
      counter("aikido.agent_server.ready.count",
        measurement: fn _ -> 1 end,
        tags: [:agent_module],
        description: "Agent activations reaching readiness, including reactivations",
        reporter_options: [nav: "Agents"]
      ),
      counter("aikido.agent_server.cron.register.count",
        measurement: fn _ -> 1 end,
        description: "Recurring schedules registered",
        reporter_options: [nav: "Agents"]
      ),
      counter("aikido.agent_server.cron.cancel.count",
        measurement: fn _ -> 1 end,
        description: "Recurring schedules cancelled",
        reporter_options: [nav: "Agents"]
      )
    ]
  end

  defp model_metrics do
    [
      counter("req_llm.request.stop.count",
        measurement: fn _ -> 1 end,
        tags: [:provider, :http_status],
        description: "Provider requests finishing, grouped by HTTP status",
        reporter_options: [nav: "AI"]
      ),
      summary("req_llm.request.stop.duration",
        tags: [:provider],
        unit: {:native, :millisecond},
        description: "Provider request duration, including streaming",
        reporter_options: [nav: "AI"]
      ),
      counter("req_llm.request.retry.count",
        measurement: fn _ -> 1 end,
        tags: [:provider, :http_status],
        description: "Native ReqLLM transport retries",
        reporter_options: [nav: "AI"]
      ),
      counter("req_llm.request.exception.count",
        measurement: fn _ -> 1 end,
        tags: [:provider, :http_status],
        description: "Provider request exceptions",
        reporter_options: [nav: "AI"]
      )
    ] ++
      Enum.map([:input_tokens, :output_tokens, :reasoning_tokens, :total_cost], fn key ->
        sum([:req_llm, :request, :stop, key],
          event_name: [:req_llm, :request, :stop],
          measurement: fn _measurements, metadata ->
            get_in(metadata, [:usage, key])
          end,
          tags: [:provider],
          description: "Reported #{key}; cost is the available USD estimate",
          reporter_options: [nav: "AI"]
        )
      end)
  end

  defp ash_metrics do
    event = [:ash, Ash.Domain.Info.short_name(AgentExamples.Agents), :action, :stop]

    [
      counter("ash.actions.count",
        measurement: fn _ -> 1 end,
        event_name: event,
        tags: [:resource_short_name, :action],
        description: "Native Ash actions across commands, reducers and tools",
        reporter_options: [nav: "Ash"]
      ),
      summary("ash.actions.duration",
        event_name: event,
        tags: [:resource_short_name, :action],
        unit: {:native, :millisecond},
        description: "Native Ash action duration, including tool execution",
        reporter_options: [nav: "Ash"]
      )
    ]
  end

  defp vm_metrics do
    [
      last_value("vm.memory.total", unit: {:byte, :megabyte}, reporter_options: [nav: "BEAM"]),
      last_value("vm.memory.processes_used",
        unit: {:byte, :megabyte},
        reporter_options: [nav: "BEAM"]
      ),
      last_value("vm.memory.binary", unit: {:byte, :megabyte}, reporter_options: [nav: "BEAM"]),
      last_value("vm.total_run_queue_lengths.cpu", reporter_options: [nav: "BEAM"]),
      last_value("vm.total_run_queue_lengths.io", reporter_options: [nav: "BEAM"])
    ]
  end
end
