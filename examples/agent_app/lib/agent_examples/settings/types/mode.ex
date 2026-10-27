defmodule AgentExamples.Settings.Types.Mode do
  @moduledoc "Whether the example uses its offline model or a configured live provider."
  use Ash.Type.Enum, values: ["offline", "live"]
end
