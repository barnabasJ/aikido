defmodule Aikido.Cron.Directives.Report do
  @moduledoc "Publishes a cron lifecycle measurement after its state transition."
  use Aikido.Directive

  typed_struct do
    field :event, :atom do
      description "Telemetry event name within the cron namespace."
      allow_nil? false
    end

    field :metadata, :map do
      description "Job identity and diagnostic measurements for the transition."
      default %{}
      allow_nil? false
    end
  end

  @impl true
  def exec(report, _signal, runtime),
    do: Aikido.Cron.Telemetry.emit(runtime, report.event, report.metadata)
end
