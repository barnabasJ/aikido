defmodule Aikido.Slice.RouteEntry do
  @moduledoc false

  defstruct [:type, :action, :priority, :match, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          type: String.t(),
          action: {module(), atom()},
          priority: integer(),
          match: (any() -> boolean()) | nil
        }
end
