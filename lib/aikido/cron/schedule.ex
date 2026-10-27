defmodule Aikido.Cron.Schedule do
  @moduledoc "A native DSL declaration for a recurring signal or slice action."
  defstruct [
    :cron,
    :action,
    :signal_type,
    :job_id,
    :timezone,
    data: %{},
    __spark_metadata__: nil
  ]
end
