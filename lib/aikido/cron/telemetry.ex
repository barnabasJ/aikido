defmodule Aikido.Cron.Telemetry do
  @moduledoc "Emits cron runtime measurements with the owning agent identity."
  def emit(runtime, event, metadata \\ %{}) do
    :telemetry.execute(
      [:aikido, :agent_server, :cron, event],
      %{system_time: System.system_time()},
      Map.merge(
        %{
          agent_id: runtime.id,
          agent_module: runtime.agent_module,
          aikido_instance: runtime.aikido,
          aikido_partition: runtime.partition
        },
        metadata
      )
    )
  end
end
