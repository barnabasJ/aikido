defmodule Aikido.Slice.Schedule do
  @moduledoc false
  defstruct [:cron, :action, :tz, :signal, data: %{}, __spark_metadata__: nil]
end
