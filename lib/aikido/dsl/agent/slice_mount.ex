defmodule Aikido.Dsl.Agent.SliceMount do
  @moduledoc false

  defstruct [:path, :module, :options, __identifier__: nil, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          path: atom(),
          module: module(),
          options: map() | keyword()
        }
end
