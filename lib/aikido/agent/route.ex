defmodule Aikido.Agent.Route do
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

  @type t :: %__MODULE__{
          type: String.t(),
          action: {module(), atom()},
          priority: integer(),
          match: (any() -> boolean()) | nil
        }
end
