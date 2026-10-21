defmodule Aikido.Slice.Route do
  @moduledoc false
  defstruct [
    :name,
    :type,
    :action,
    :match,
    :signal_module,
    :implementation,
    public?: nil,
    priority: 0,
    __spark_metadata__: nil
  ]
end
