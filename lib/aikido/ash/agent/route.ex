defmodule Aikido.Ash.Agent.Route do
  @moduledoc false

  defstruct [
    :type,
    :action,
    :priority,
    :match,
    :signal_module,
    :implementation,
    public?: true,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          type: String.t(),
          action: {module(), atom()},
          priority: integer(),
          match: (any() -> boolean()) | nil
        }
end
